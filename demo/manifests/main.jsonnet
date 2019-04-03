local kube = import './vendor/kube-prod-runtime/lib/kube.libsonnet';

local cert_manager = import './vendor/kube-prod-runtime/components/cert-manager.jsonnet';
local externaldns = import './vendor/kube-prod-runtime/components/externaldns.jsonnet';

local contour = import './components/contour.jsonnet';
local dex = import './components/dex.jsonnet';
local gangway = import './components/gangway.jsonnet';

local config = import './config.json';

local gangway_key = import './gangway-key';
local oidc_client_secret = import './oidc-client-secret';

local base_domain = 'josh-gcp.jetstack.net';
local namespace = 'auth';

{
  config:: config,

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
    letsencrypt_contact_email:: 'joshua.vanleeuwen@jetstack.io',
    letsencrypt_environment:: 'prod',

    letsencryptStaging+: {
      spec+: {
        acme+: {
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

  cert_manager_google_issuer: cert_manager.Issuer('clouddns') {
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
      ownerId: base_domain,
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

  namespace: kube.Namespace(namespace),

  contour: contour {
    base_domain:: base_domain,

    metadata:: {
      metadata+: {
        namespace: namespace,
      },
    },
  },

  dex: dex {
    base_domain:: base_domain,
    oidc_client_secret:: oidc_client_secret,

    metadata:: {
      metadata+: {
        namespace: namespace,
      },
    },
  },

  dexPasswordJosh: dex.Password('josh', 'joshua.vanleeuwen@jetstack.io', '$2y$10$i2.tSLkchjnpvnI73iSW/OPAVriV9BWbdfM6qemBM1buNRu81.ZG.'),  // plaintext: secure

  gangway: gangway {
    secret_key:: gangway_key,
    oidc_client_secret:: oidc_client_secret,

    base_domain:: base_domain,

    metadata:: {
      metadata+: {
        namespace: namespace,
      },
    },
  },
}
