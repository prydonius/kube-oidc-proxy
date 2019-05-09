local kube = import './vendor/kube-prod-runtime/lib/kube.libsonnet';

local cert_manager = import './components/cert-manager.jsonnet';
local externaldns = import './vendor/kube-prod-runtime/components/externaldns.jsonnet';

local contour = import './components/contour.jsonnet';
local dex = import './components/dex.jsonnet';
local gangway = import './components/gangway.jsonnet';
local kube_oidc_proxy = import './components/kube-oidc-proxy.jsonnet';

local config = import './config.json';

local IngressRouteTLSPassthrough(namespace, name, domain, serviceName, servicePort) = contour.IngressRoute(
  namespace,
  name,
) {
  spec+: {
    virtualhost: {
      fqdn: domain,
      tls: {
        passthrough: true,
      },
    },
    tcpproxy: {
      services: [
        {
          name: serviceName,
          port: servicePort,
        },
      ],
    },
    routes: [
      {
        match: '/',
        services: [
          {
            name: 'fake',
            port: 6666,
          },
        ],
      },
    ],
  },
};

local only_master(obj) =
  if std.extVar('master') == 'true' then
    obj
  else
    {};

local apply_ca_issuer(ca_crt, ca_key, obj) =
  if ca_crt != '' && ca_key != '' then
    {
      issuer: obj,
      secret: kube.Secret(obj.spec.ca.secretName) + cert_manager.metadata {
        metadata+: {
          namespace: 'kube-system',
        },

        data_+: {
          'tls.crt': ca_crt,
          'tls.key': ca_key,
        },
      },
    }
  else
    {};


{
  config:: config,

  base_domain:: error 'base_domain is undefined',

  p:: '',

  default_replicas:: 1,

  namespace:: 'auth',

  ns: kube.Namespace($.namespace),

  dex_domain:: $.dex.domain,

  ca_crt:: $.config.cert_manager.ca_crt,
  ca_key:: $.config.cert_manager.ca_key,

  cert_manager: cert_manager {
    google_secret: kube.Secret($.cert_manager.p + 'clouddns-google-credentials') + $.cert_manager.metadata {
      data_+: {
        'credentials.json': $.config.cert_manager.service_account_credentials,
      },
    },

    metadata:: {
      metadata+: {
        namespace: 'kube-system',
      },
    },
    letsencrypt_environment:: 'prod',

    ca_issuer: apply_ca_issuer($.ca_crt, $.ca_key, $.cert_manager.ClusterIssuer($.p + 'ca-issuer') {
      local this = self,
      spec+: {
        ca+: {
          secretName: $.cert_manager.ca_secret_name,
        },
      },
    }),

    letsencryptStaging+: {
      spec+: {
        acme+: {
          http01: null,
          dns01: {
            providers: [{
              name: 'clouddns',
              clouddns: {
                project: $.config.cert_manager.project,
                serviceAccountSecretRef: {
                  name: $.cert_manager.google_secret.metadata.name,
                  key: 'credentials.json',
                },
              },
            }],
          },
        },
      },
    },
  },

  externaldns: externaldns {
    metadata:: {
      metadata+: {
        namespace: 'kube-system',
      },
    },

    gcreds: kube.Secret($.externaldns.p + 'externaldns-google-credentials') + $.externaldns.metadata {
      data_+: {
        'credentials.json': $.config.externaldns.service_account_credentials,
      },
    },

    deploy+: {
      ownerId: $.base_domain,
      spec+: {
        template+: {
          spec+: {
            volumes_+: {
              gcreds: kube.SecretVolume($.externaldns.gcreds),
            },
            containers_+: {
              edns+: {
                args_+: {
                  provider: 'google',
                  'google-project': $.config.externaldns.project,
                },
                env_+: {
                  GOOGLE_APPLICATION_CREDENTIALS: '/google/credentials.json',
                },
                volumeMounts_+: {
                  gcreds: { mountPath: '/google', readOnly: true },
                },
              },
            },
          },
        },
      },
    },
  },

  contour: contour {
    base_domain:: $.base_domain,
    p:: $.p,

    metadata:: {
      metadata+: {
        namespace: $.namespace,
      },
    },

    deployment+: {
      spec+: {
        replicas: $.default_replicas,
      },
    },

    svc+: {
      metadata+: {
        annotations+: {
          // this add a final dot to the domain name and joins the list
          'external-dns.alpha.kubernetes.io/hostname': std.join(',', std.map(
            (function(o) o + '.'),
            [$.dex_domain, $.gangway.domain, $.kube_oidc_proxy.domain],
          )),
        },
      },
    },
  },

  dex: only_master(dex {
    local this = self,
    base_domain:: $.base_domain,
    p:: $.p,
    metadata:: {
      metadata+: {
        namespace: $.namespace,
      },
    },

    deployment+: {
      spec+: {
        replicas: $.default_replicas,
      },
    },

    certificate: cert_manager.Certificate(
      $.namespace,
      this.name,
      $.cert_manager.letsencryptProd,
      [this.domain]
    ),
    ingressRoute: IngressRouteTLSPassthrough($.namespace, this.name, this.domain, this.name, 5556),
  }),

  gangway: gangway {
    local this = self,
    base_domain:: $.base_domain,
    p:: $.p,
    metadata:: {
      metadata+: {
        namespace: $.namespace,
      },
    },

    // configure let's encrypt root by default
    configMap+: {
      data+: {
        'cluster-ca.crt': |||
          -----BEGIN CERTIFICATE-----
          MIIEkjCCA3qgAwIBAgIQCgFBQgAAAVOFc2oLheynCDANBgkqhkiG9w0BAQsFADA/
          MSQwIgYDVQQKExtEaWdpdGFsIFNpZ25hdHVyZSBUcnVzdCBDby4xFzAVBgNVBAMT
          DkRTVCBSb290IENBIFgzMB4XDTE2MDMxNzE2NDA0NloXDTIxMDMxNzE2NDA0Nlow
          SjELMAkGA1UEBhMCVVMxFjAUBgNVBAoTDUxldCdzIEVuY3J5cHQxIzAhBgNVBAMT
          GkxldCdzIEVuY3J5cHQgQXV0aG9yaXR5IFgzMIIBIjANBgkqhkiG9w0BAQEFAAOC
          AQ8AMIIBCgKCAQEAnNMM8FrlLke3cl03g7NoYzDq1zUmGSXhvb418XCSL7e4S0EF
          q6meNQhY7LEqxGiHC6PjdeTm86dicbp5gWAf15Gan/PQeGdxyGkOlZHP/uaZ6WA8
          SMx+yk13EiSdRxta67nsHjcAHJyse6cF6s5K671B5TaYucv9bTyWaN8jKkKQDIZ0
          Z8h/pZq4UmEUEz9l6YKHy9v6Dlb2honzhT+Xhq+w3Brvaw2VFn3EK6BlspkENnWA
          a6xK8xuQSXgvopZPKiAlKQTGdMDQMc2PMTiVFrqoM7hD8bEfwzB/onkxEz0tNvjj
          /PIzark5McWvxI0NHWQWM6r6hCm21AvA2H3DkwIDAQABo4IBfTCCAXkwEgYDVR0T
          AQH/BAgwBgEB/wIBADAOBgNVHQ8BAf8EBAMCAYYwfwYIKwYBBQUHAQEEczBxMDIG
          CCsGAQUFBzABhiZodHRwOi8vaXNyZy50cnVzdGlkLm9jc3AuaWRlbnRydXN0LmNv
          bTA7BggrBgEFBQcwAoYvaHR0cDovL2FwcHMuaWRlbnRydXN0LmNvbS9yb290cy9k
          c3Ryb290Y2F4My5wN2MwHwYDVR0jBBgwFoAUxKexpHsscfrb4UuQdf/EFWCFiRAw
          VAYDVR0gBE0wSzAIBgZngQwBAgEwPwYLKwYBBAGC3xMBAQEwMDAuBggrBgEFBQcC
          ARYiaHR0cDovL2Nwcy5yb290LXgxLmxldHNlbmNyeXB0Lm9yZzA8BgNVHR8ENTAz
          MDGgL6AthitodHRwOi8vY3JsLmlkZW50cnVzdC5jb20vRFNUUk9PVENBWDNDUkwu
          Y3JsMB0GA1UdDgQWBBSoSmpjBH3duubRObemRWXv86jsoTANBgkqhkiG9w0BAQsF
          AAOCAQEA3TPXEfNjWDjdGBX7CVW+dla5cEilaUcne8IkCJLxWh9KEik3JHRRHGJo
          uM2VcGfl96S8TihRzZvoroed6ti6WqEBmtzw3Wodatg+VyOeph4EYpr/1wXKtx8/
          wApIvJSwtmVi4MFU5aMqrSDE6ea73Mj2tcMyo5jMd6jmeWUHK8so/joWUoHOUgwu
          X4Po1QYz+3dszkDqMp4fklxBwXRsW10KXzPMTZ+sOPAveyxindmjkW8lGy+QsRlG
          PfZ+G6Z6h7mjem0Y+iWlkYcV4PIWL1iwBi8saCbGS5jN2p8M+X+Q7UNKEkROb3N6
          KOqkqm57TH2H3eDJAkSnh6/DNFu0Qg==
          -----END CERTIFICATE-----
        |||,
      },
    },

    deployment+: {
      spec+: {
        replicas: $.default_replicas,
      },
    },

    certificate: cert_manager.Certificate(
      $.namespace,
      this.name,
      $.cert_manager.letsencryptProd,
      [this.domain]
    ),
    ingressRoute: IngressRouteTLSPassthrough($.namespace, this.name, this.domain, this.name, 8080),

    sessionSecurityKey: $.config.gangway.session_security_key,

    config+: {
      authorizeURL: 'https://' + $.dex_domain + '/auth',
      tokenURL: 'https://' + $.dex_domain + '/token',
      apiServerURL: 'https://' + $.kube_oidc_proxy.domain,
      clientID: $.config.gangway.client_id,
      clientSecret: $.config.gangway.client_secret,
      clusterCAPath: this.config_path + '/cluster-ca.crt',
    },

    dexClient: only_master(dex.Client(this.config.clientID) + $.dex.metadata {
      secret: this.config.clientSecret,
      redirectURIs: [
        this.config.redirectURL,
      ],
    }),
  },

  kube_oidc_proxy: kube_oidc_proxy {
    local this = self,
    base_domain:: $.base_domain,
    p:: $.p,
    metadata:: {
      metadata+: {
        namespace: $.namespace,
      },
    },

    config+: {
      oidc+: {
        issuerURL: 'https://' + $.dex_domain,
        clientID: $.config.gangway.client_id,
      },
    },

    deployment+: {
      spec+: {
        replicas: $.default_replicas,
      },
    },

    certificate: cert_manager.Certificate(
      $.namespace,
      this.name,
      if $.ca_crt != '' && $.ca_key != '' then $.cert_manager.ca_issuer.issuer else $.cert_manager.letsencryptProd,
      [this.domain]
    ),
    ingressRoute: IngressRouteTLSPassthrough($.namespace, this.name, this.domain, this.name, 443),
  },
}
