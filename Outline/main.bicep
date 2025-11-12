@description('The location for all resources')
param location string = resourceGroup().location

@description('The name of the Container App')
param containerAppName string = 'outline-app'

@description('The name of the Container App Environment')
param environmentName string = 'outline-env'

@description('Your Outline domain URL (e.g., https://outline.yourdomain.com)')
param outlineUrl string

@description('PostgreSQL admin username')
param postgresAdminUsername string = 'outlineadmin'

@description('PostgreSQL admin password')
@secure()
param postgresAdminPassword string

@description('PostgreSQL server name (must be globally unique). Leave empty to auto-generate.')
param postgresServerName string = 'outline-postgres-${uniqueString(resourceGroup().id)}'

// Use default if empty string provided
var effectivePostgresServerName = empty(postgresServerName) ? 'outline-postgres-${uniqueString(resourceGroup().id)}' : postgresServerName

@description('PostgreSQL database name')
param postgresDatabaseName string = 'outline'

@description('PostgreSQL SKU tier (Burstable, GeneralPurpose, MemoryOptimized)')
param postgresSkuTier string = 'Burstable'

@description('PostgreSQL SKU name (e.g., Standard_B1ms, GP_Standard_D2s_v3)')
param postgresSkuName string = 'Standard_B1ms'

@description('Redis cache name (must be globally unique). Leave empty to auto-generate.')
param redisCacheName string = 'outline-redis-${uniqueString(resourceGroup().id)}'

// Use default if empty string provided
var effectiveRedisCacheName = empty(redisCacheName) ? 'outline-redis-${uniqueString(resourceGroup().id)}' : redisCacheName

@description('Redis SKU (Basic, Standard, Premium)')
param redisSku string = 'Basic'

@description('Redis capacity (C0, C1, C2, C3, C4, C5, C6, P1, P2, P3, P4, P5)')
param redisCapacity int = 0

@description('Storage account name (must be globally unique, lowercase, 3-24 chars). Leave empty to auto-generate.')
param storageAccountName string = 'outline${uniqueString(resourceGroup().id)}'

// Use default if empty string provided - ensure lowercase and valid length
var effectiveStorageAccountName = empty(storageAccountName) ? 'outline${toLower(uniqueString(resourceGroup().id))}' : toLower(storageAccountName)

@description('Storage container name for Outline files')
param storageContainerName string = 'outline-files'

@description('Secret key for Outline (generate with: openssl rand -hex 32)')
@secure()
param secretKey string

@description('Utils secret for Outline (generate with: openssl rand -hex 32)')
@secure()
param utilsSecret string

@description('Azure AD Client ID')
@secure()
param azureClientId string

@description('Azure AD Client Secret')
@secure()
param azureClientSecret string

@description('Azure AD Resource App ID')
param azureResourceAppId string = '00000003-0000-0000-c000-000000000000'

@description('Use Azure Storage Account for file storage (true) or external S3 (false)')
param useAzureStorage bool = true

@description('Use Azure File Storage as volume mount (true) or S3-compatible storage (false). Requires useAzureStorage=true')
param useVolumeMount bool = true

@description('Azure File Share name for volume mount')
param fileShareName string = 'outline-files'

@description('AWS Access Key ID for S3 storage (only if useAzureStorage is false)')
@secure()
param awsAccessKeyId string = ''

@description('AWS Secret Access Key for S3 storage (only if useAzureStorage is false)')
@secure()
param awsSecretAccessKey string = ''

@description('AWS Region for S3 (only if useAzureStorage is false)')
param awsRegion string = 'us-east-1'

@description('S3 Bucket Name (only if useAzureStorage is false)')
param s3BucketName string = ''

@description('Log Analytics Workspace name')
param logAnalyticsWorkspaceName string = 'outline-logs'

// PostgreSQL Flexible Server
resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
  name: effectivePostgresServerName
  location: location
  sku: {
    name: postgresSkuName
    tier: postgresSkuTier
  }
  properties: {
    administratorLogin: postgresAdminUsername
    administratorLoginPassword: postgresAdminPassword
    version: '15'
    storage: {
      storageSizeGB: 32
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
}

// PostgreSQL Firewall Rule - Allow Azure Services
resource postgresFirewallRule 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = {
  parent: postgresServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// PostgreSQL Database
resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview' = {
  parent: postgresServer
  name: postgresDatabaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Enable PostgreSQL extensions required for Outline migrations
// This includes uuid-ossp, unaccent, and pg_trgm extensions
resource enablePostgresExtensions 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'enable-postgres-extensions-${uniqueString(resourceGroup().id)}'
  location: location
  kind: 'AzureCLI'
  properties: {
    azCliVersion: '2.53.0'
    scriptContent: '''
      # Install PostgreSQL client and Python dependencies
      apt-get update -qq && apt-get install -y postgresql-client python3-pip > /dev/null 2>&1 || \
      yum install -y postgresql python3-pip > /dev/null 2>&1 || \
      apk add --no-cache postgresql-client python3 py3-pip > /dev/null 2>&1
      
      # Install psycopg2 for Python
      pip3 install psycopg2-binary --quiet
      
      # Python script to enable extensions
      python3 << EOF
      import psycopg2
      import sys
      
      extensions = ["uuid-ossp", "unaccent", "pg_trgm"]
      
      try:
          conn = psycopg2.connect(
              host="${postgresServer.properties.fullyQualifiedDomainName}",
              database="${postgresDatabaseName}",
              user="${postgresAdminUsername}",
              password="${postgresAdminPassword}",
              sslmode="require"
          )
          cur = conn.cursor()
          
          for ext in extensions:
              try:
                  cur.execute(f'CREATE EXTENSION IF NOT EXISTS "{ext}";')
                  conn.commit()
                  print(f"Successfully enabled {ext} extension")
              except Exception as e:
                  print(f"Warning: Failed to enable {ext} extension: {e}")
          
          cur.close()
          conn.close()
          print("Extension setup completed")
      except Exception as e:
          print(f"Error connecting to database: {e}")
          sys.exit(1)
      EOF
    '''
    timeout: 'PT10M'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'PT1H'
  }
  dependsOn: [
    postgresDatabase
    postgresFirewallRule
  ]
}

// Azure Cache for Redis
resource redisCache 'Microsoft.Cache/redis@2023-08-01' = {
  name: effectiveRedisCacheName
  location: location
  properties: {
    sku: {
      name: redisSku
      family: redisSku == 'Premium' ? 'P' : (redisSku == 'Standard' ? 'C' : 'C')
      capacity: redisCapacity
    }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    redisConfiguration: redisSku != 'Basic' ? {
      maxmemoryReserved: '2'
      maxmemoryPolicy: 'allkeys-lru'
    } : {}
  }
}

// Note: Redis keys are retrieved using listKeys() function, not as a separate resource

// Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: effectiveStorageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

// Blob Service
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    cors: {
      corsRules: []
    }
    deleteRetentionPolicy: {
      enabled: false
    }
  }
}

// Storage Container (for S3-compatible storage if not using volume mounts)
resource storageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: storageContainerName
  properties: {
    publicAccess: 'None'
  }
}

// File Service (for Azure Files)
resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {}
}

// Azure File Share (for volume mounts)
resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileService
  name: fileShareName
  properties: {
    accessTier: 'TransactionOptimized'
    shareQuota: 100
  }
}

// Get Redis access keys
var redisKeys = redisCache.listKeys()
var redisPrimaryKey = redisKeys.primaryKey

// Get Storage Account keys
var storageKeys = storageAccount.listKeys()
var storageAccountKey = storageKeys.keys[0].value

// Generate connection strings
var postgresConnectionString = 'postgres://${postgresAdminUsername}:${postgresAdminPassword}@${postgresServer.properties.fullyQualifiedDomainName}:5432/${postgresDatabaseName}?sslmode=require'
var redisConnectionString = 'rediss://:${redisPrimaryKey}@${redisCache.properties.hostName}:6380?ssl=true'
var storageEndpoint = 'https://${storageAccount.name}.blob.${environment().suffixes.storage}'

// Log Analytics Workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-06-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Container App Environment
resource containerAppEnvironment 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: environmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
  }
}

// Storage mount in Container Apps Environment (if using volume mounts)
// This is a child resource that registers the Azure File Share with the Environment
// All resources created in proper dependency order - no deployment scripts needed!
resource environmentStorageMount 'Microsoft.App/managedEnvironments/storages@2023-05-01' = if (useAzureStorage && useVolumeMount) {
  parent: containerAppEnvironment
  name: 'outline-storage'
  properties: {
    azureFile: {
      accountName: storageAccount.name
      shareName: fileShareName
      accessMode: 'ReadWrite'
      accountKey: storageAccountKey
    }
  }
  dependsOn: [
    fileShare
  ]
}

// Container App (depends on storage mount if using volume mounts)
resource containerApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: containerAppName
  location: location
  dependsOn: useAzureStorage && useVolumeMount ? [
    containerAppEnvironment
    environmentStorageMount
  ] : [
    containerAppEnvironment
  ]
  properties: {
    managedEnvironmentId: containerAppEnvironment.id
    configuration: {
      ingress: {
        external: true
        targetPort: 3000
        allowInsecure: false
        transport: 'auto'
        traffic: [
          {
            weight: 100
            latestRevision: true
          }
        ]
      }
      secrets: [
        {
          name: 'secret-key'
          value: secretKey
        }
        {
          name: 'utils-secret'
          value: utilsSecret
        }
        {
          name: 'database-url'
          value: postgresConnectionString
        }
        {
          name: 'redis-url'
          value: redisConnectionString
        }
        {
          name: 'azure-client-id'
          value: azureClientId
        }
        {
          name: 'azure-client-secret'
          value: azureClientSecret
        }
        {
          name: 'aws-access-key-id'
          value: useAzureStorage ? storageAccount.name : awsAccessKeyId
        }
        {
          name: 'aws-secret-access-key'
          value: useAzureStorage ? storageAccountKey : awsSecretAccessKey
        }
        {
          name: 'azure-storage-key'
          value: useAzureStorage && useVolumeMount ? storageAccountKey : ''
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'outline'
          image: 'outlinewiki/outline:1.0.1'
          env: [
            {
              name: 'NODE_ENV'
              value: 'production'
            }
            {
              name: 'URL'
              value: outlineUrl
            }
            {
              name: 'PORT'
              value: '3000'
            }
            {
              name: 'WEB_CONCURRENCY'
              value: '1'
            }
            {
              name: 'SECRET_KEY'
              secretRef: 'secret-key'
            }
            {
              name: 'UTILS_SECRET'
              secretRef: 'utils-secret'
            }
            {
              name: 'DATABASE_URL'
              secretRef: 'database-url'
            }
            {
              name: 'PGSSLMODE'
              value: 'require'
            }
            {
              name: 'REDIS_URL'
              secretRef: 'redis-url'
            }
            {
              name: 'FILE_STORAGE'
              value: useAzureStorage && useVolumeMount ? 'local' : 's3'
            }
            {
              name: 'FILE_STORAGE_LOCAL_ROOT_DIR'
              value: useAzureStorage && useVolumeMount ? '/var/lib/outline/data' : ''
            }
            {
              name: 'AWS_ACCESS_KEY_ID'
              secretRef: 'aws-access-key-id'
            }
            {
              name: 'AWS_SECRET_ACCESS_KEY'
              secretRef: 'aws-secret-access-key'
            }
            {
              name: 'AWS_REGION'
              value: useAzureStorage && !useVolumeMount ? location : awsRegion
            }
            {
              name: 'AWS_S3_UPLOAD_BUCKET_NAME'
              value: useAzureStorage && !useVolumeMount ? storageContainerName : s3BucketName
            }
            {
              name: 'AWS_S3_UPLOAD_BUCKET_URL'
              value: useAzureStorage && !useVolumeMount ? storageEndpoint : ''
            }
            {
              name: 'AWS_S3_FORCE_PATH_STYLE'
              value: useAzureStorage && !useVolumeMount ? 'true' : 'false'
            }
            {
              name: 'AWS_S3_ACL'
              value: 'private'
            }
            {
              name: 'FORCE_HTTPS'
              value: 'true'
            }
            {
              name: 'AZURE_CLIENT_ID'
              secretRef: 'azure-client-id'
            }
            {
              name: 'AZURE_CLIENT_SECRET'
              secretRef: 'azure-client-secret'
            }
            {
              name: 'AZURE_RESOURCE_APP_ID'
              value: azureResourceAppId
            }
            {
              name: 'RATE_LIMITER_ENABLED'
              value: 'true'
            }
            {
              name: 'RATE_LIMITER_REQUESTS'
              value: '1000'
            }
            {
              name: 'RATE_LIMITER_DURATION_WINDOW'
              value: '60'
            }
            {
              name: 'LOG_LEVEL'
              value: 'info'
            }
            {
              name: 'ALLOWED_IFRAME_HOSTS'
              value: 'scribehow.com,*.scribehow.com,app.scribehow.com'
            }
          ]
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          // Mount Azure File Share as volume if using volume mounts
          volumeMounts: useAzureStorage && useVolumeMount ? [
            {
              volumeName: 'outline-storage'
              mountPath: '/var/lib/outline/data'
            }
          ] : []
        }
      ]
      // Define volumes for the container app (storage must be configured in environment first)
      volumes: useAzureStorage && useVolumeMount ? [
        {
          name: 'outline-storage'
          storageType: 'AzureFile'
          storageName: 'outline-storage'
        }
      ] : []
      scale: {
        minReplicas: 1
        maxReplicas: 10
        rules: [
          {
            name: 'http-rule'
            http: {
              metadata: {
                concurrentRequests: '100'
              }
            }
          }
        ]
      }
    }
  }
}

output containerAppFqdn string = containerApp.properties.configuration.ingress.fqdn
output containerAppName string = containerApp.name
output postgresServerFqdn string = postgresServer.properties.fullyQualifiedDomainName
output postgresDatabaseName string = postgresDatabaseName
output redisHostName string = redisCache.properties.hostName
output storageAccountName string = storageAccount.name
output storageContainerName string = storageContainerName
output azureAdRedirectUri string = 'https://${containerApp.properties.configuration.ingress.fqdn}/auth/azure.callback'

