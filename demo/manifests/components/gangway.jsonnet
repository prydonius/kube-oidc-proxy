local kube = import '../vendor/kube-prod-runtime/lib/kube.libsonnet';
local utils = import '../vendor/kube-prod-runtime/lib/utils.libsonnet';

local GANGWAY_IMAGE = 'gcr.io/heptio-images/gangway:v3.0.0';

local GANGWAY_HTTPS_PORT = 8080;
local GANGWAY_SECRET_VOLUME_PATH = '/etc/gangway/tls';

{
  p:: '',

  secret_key:: {data: ''},
  oidc_client_secret:: {data: ''},

  base_domain:: 'gangway.cluster.local',

  cluster_name:: 'mycluster',

  namespace:: 'gangway',

  gangway_url:: 'https://gangway.' + $.base_domain,
  kubernetes_url:: 'https://kubernetes-api.' + $.base_domain,
  authorize_url:: 'https://dex.' + $.base_domain + '/dex/auth',
  token_url:: 'https://dex.' + $.base_domain + '/dex/token',

  labels:: {
    metadata+: {
      labels+: {
        app: 'gangway',
      },
    },
  },

  metadata:: $.labels {
    metadata+: {
      namespace: $.namespace,
    },
  },

  secretKey: kube.Secret('gangway-key') + $.metadata {
    data+: {
      sessionkey: $.secret_key.data,
    },
  },

  certificate: kube._Object('certmanager.k8s.io/v1alpha1', 'Certificate', 'gangway') + $.metadata{
    spec: {
      acme: {
        config: [{
          domains: [
            'gangway.' + $.base_domain,
          ],
          http01: {
            'ingressClass': 'contour',
          }
        }],
      },

      dnsNames: [
        'gangway.' + $.base_domain,
      ],

      issuerRef: {
        kind: 'ClusterIssuer',
        name: 'letsencrypt-prod',
      },
      secretName: 'gangway-tls',
    },
  },

  gangwayIngress: kube._Object('contour.heptio.com/v1beta1', 'IngressRoute', 'gangway') + $.metadata {
    spec+: {
      virtualhost: {
        fqdn: 'gangway.' + $.base_domain,
        tls: {
          passthrough: true,
          #secretName: 'contour-tls',
        }
      },
      #tcpproxy: [{
      #  services: [{
      #    name: 'gangway',
      #    port: GANGWAY_HTTPS_PORT,
      #  }],
      #}],
      routes: [
        {
          match: "/",
          enableWebsockets: false,
          services: [{
            name: 'gangway',
            port: GANGWAY_HTTPS_PORT,
          }],
        }
      ],
      #routes: [
      #  {
      #    match: '/gangway',
      #    prefixRewrite: '/',
      #  }
      #],
    },
  },

  config:: {
    usernameClaim: 'sub',
    apiServerURL: $.kubernetes_url,
    redirectURL: $.gangway_url + '/callback',
    clusterName: $.cluster_name,
    authorizeURL: $.authorize_url,
    tokenURL: $.token_url,
    clientID: 'gangway',
    clientSecret: $.oidc_client_secret.data,
    serveTLS: true,
    certFile: '/etc/gangway/tls/tls.crt',
    keyFile: '/etc/gangway/tls/tls.key',
  },

  configMap: kube.ConfigMap($.p + 'gangway') + $.metadata {
    data+: {
      'gangway.yaml': std.manifestJsonEx($.config, '  '),
    },
  },

  deployment: kube.Deployment($.p + 'gangway') + $.metadata {
    local this = self,
    spec+: {
      replicas: 3,
      template+: {
        metadata+: {
          annotations+: {
            'config/hash': std.md5(std.escapeStringJson($.configMap)),
          },
        },
        spec+: {
          affinity: kube.PodZoneAntiAffinityAnnotation(this.spec.template),
          default_container: 'gangway',
          volumes_+: {
            config: kube.ConfigMapVolume($.configMap),
            secrets: {
              secret: { secretName: 'gangway-tls' },
            },
          },
          containers_+: {
            gangway: kube.Container('gangway') {
              image: GANGWAY_IMAGE,
              command: ['gangway'],
              args: [
                '-config',
                '/config/gangway.yaml',
              ],
              ports_+: {
                https: { containerPort: GANGWAY_HTTPS_PORT },
              },
              env_+: {
                GANGWAY_PORT: '8080',
                GANGWAY_SESSION_SECURITY_KEY: {
                  secretKeyRef: {
                    name: 'gangway-key',
                    key: 'sessionkey',
                  },
                },
              },
              #readinessProbe: {
              #  httpGet: { path: '/', port: GANGWAY_HTTPS_PORT },
              #  periodSeconds: 10,
              #},
              #livenessProbe: {
              #  httpGet: { path: '/', port: GANGWAY_HTTPS_PORT },
              #  initialDelaySeconds: 20,
              #  periodSeconds: 10,
              #},
              volumeMounts_+: {
                config: { mountPath: '/config' },
                secrets: {
                  mountPath: GANGWAY_SECRET_VOLUME_PATH,
                  readOnly: true,
                },
              },
            },
          },
        },
      },
    },
  },

  svc: kube.Service($.p + 'gangway') + $.metadata {
    target_pod: $.deployment.spec.template,
  },
}
