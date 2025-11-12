# Outline Azure Container Apps Deployment

This directory contains everything needed to deploy Outline to Azure Container Apps. The Bicep template automatically creates all required resources including PostgreSQL, Redis, and Azure File Storage.

## Quick Start

1. **Install Azure CLI** (if not already installed)
   ```bash
   # macOS
   brew install azure-cli
   
   # Linux
   curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
   
   # Windows
   # Download from https://aka.ms/InstallAzureCLI
   ```

2. **Login to Azure**
   ```bash
   az login
   az account set --subscription "your-subscription-id"
   ```

3. **Generate Secrets**
   ```bash
   # Generate SECRET_KEY
   openssl rand -hex 32
   
   # Generate UTILS_SECRET
   openssl rand -hex 32
   ```

4. **Update Parameters**
   - Edit `azuredeploy.parameters.json`
   - Update `secretKey` and `utilsSecret` with generated values
   - Update `postgresAdminPassword` with a strong password
   - Update `azureClientId` and `azureClientSecret` with your Azure AD app credentials
   - **Note**: You can leave `outlineUrl` as the placeholder for now - we'll update it after deployment with the actual FQDN

5. **Deploy**
   ```bash
   cd Azure
   chmod +x deploy.sh
   ./deploy.sh
   ```

6. **Update Configuration After Deployment**
   - The script will show your Container App FQDN (e.g., `outline-app.xyz123.azurecontainerapps.io`)
   - Update the `outlineUrl` in the Container App (see Post-Deployment section below)
   - Add Azure AD redirect URI: `https://your-fqdn.azurecontainerapps.io/auth/azure.callback`
   - Go to Azure Portal → Azure AD → App registrations → Your app → Authentication

## Prerequisites

1. **Azure CLI** installed and configured
2. **Azure Subscription** with permissions to create:
   - Resource Groups
   - Container Apps
   - PostgreSQL Flexible Servers
   - Redis Caches
   - Storage Accounts
   - Log Analytics Workspaces
3. **Azure AD App Registration** with:
   - Client ID
   - Client Secret
   - Redirect URI (configured after deployment)

## What Gets Created

The Bicep template automatically creates:

1. **Azure Database for PostgreSQL Flexible Server**
   - Database: `outline`
   - Auto-configured with SSL
   - Firewall rule for Azure services

2. **Azure Cache for Redis**
   - SSL/TLS only
   - Auto-configured connection

3. **Azure Storage Account**
   - Azure File Share (for volume mounts - default)
   - Blob container (for S3-compatible storage - alternative)

4. **Container Apps Environment**
   - Managed environment with logging

5. **Container App**
   - Running Outline
   - Auto-scaling configured
   - Volume mount for persistent storage

6. **Log Analytics Workspace**
   - For monitoring and logs

## Configuration Steps

### 1. Update Parameters File

Edit `azuredeploy.parameters.json` and update these required values:

**Required:**
- `secretKey`: Generated with `openssl rand -hex 32`
- `utilsSecret`: Generated with `openssl rand -hex 32`
- `postgresAdminPassword`: Strong password for PostgreSQL
- `azureClientId`: Your Azure AD Client ID
- `azureClientSecret`: Your Azure AD Client Secret

**Can be updated after deployment:**
- `outlineUrl`: Your public domain URL. You can use a placeholder initially (e.g., `https://outline.yourdomain.com`) and update it after deployment with the actual Container App FQDN or your custom domain

**Optional (have defaults):**
- `useVolumeMount`: `true` (uses Azure File Storage volume mounts - recommended)
- `fileShareName`: `outline-files` (name of the Azure File Share)
- `useAzureStorage`: `true` (uses Azure Storage, set to `false` for external S3)
- Resource names (auto-generated if left empty)

### 2. Deploy

#### Option A: Using the deployment script (Recommended)

```bash
cd Azure
chmod +x deploy.sh
./deploy.sh
```

The script will:
- Check Azure CLI installation
- Verify you're logged in
- Create resource group
- Deploy all infrastructure
- Show your Container App FQDN

#### Option B: Manual deployment

```bash
# Create resource group
az group create --name outline-rg --location centralus

# Deploy infrastructure
az deployment group create \
  --resource-group outline-rg \
  --template-file main.bicep \
  --parameters @azuredeploy.parameters.json
```

### 3. Update Azure AD Redirect URI

After deployment, you'll get a FQDN. Update your Azure AD app registration:

1. Go to [Azure Portal](https://portal.azure.com) → **Azure Active Directory** → **App registrations**
2. Find your app (by Client ID)
3. Go to **Authentication**
4. Add redirect URI: `https://your-container-app-fqdn.azurecontainerapps.io/auth/azure.callback`
5. Save

### 4. Update Outline URL

After deployment, you'll get a Container App FQDN. Update the `outlineUrl` environment variable:

```bash
# Get your Container App FQDN
FQDN=$(az containerapp show \
  --name outline-app \
  --resource-group outline-rg \
  --query "properties.configuration.ingress.fqdn" \
  --output tsv)

# Update the URL (use the FQDN or your custom domain)
az containerapp update \
  --name outline-app \
  --resource-group outline-rg \
  --set-env-vars "URL=https://${FQDN}"
```

**Or if using a custom domain:**
```bash
az containerapp update \
  --name outline-app \
  --resource-group outline-rg \
  --set-env-vars "URL=https://outline.yourdomain.com"
```

### 5. Access Your Outline Instance

Visit your Container App FQDN (shown after deployment) and sign in with Azure AD!

## Advanced: Manual Resource Creation

```bash
# Create Container App Environment
az containerapp env create \
  --name outline-env \
  --resource-group outline-rg \
  --location eastus

# Create Container App
az containerapp create \
  --name outline-app \
  --resource-group outline-rg \
  --environment outline-env \
  --image docker.getoutline.com/outlinewiki/outline:latest \
  --target-port 3000 \
  --ingress external \
  --env-vars \
    NODE_ENV=production \
    URL=https://your-domain.com \
    PORT=3000 \
  --secrets \
    secret-key="your-secret-key" \
    database-url="your-database-url" \
    redis-url="your-redis-url" \
  --cpu 1.0 \
  --memory 2Gi \
  --min-replicas 1 \
  --max-replicas 10
```

## Storage Configuration

### Default: Azure File Storage Volume Mounts (Recommended)

The template is configured to use Azure File Storage as volume mounts by default. This is the **simplest and most Azure-native** approach.

**How it works:**
- Azure File Share is created automatically
- Mounted at `/var/lib/outline/data` in the container
- Outline uses local storage (`FILE_STORAGE=local`)
- Files persist across restarts and are shared across replicas

**Configuration:**
- `useVolumeMount=true` (default)
- `fileShareName=outline-files` (default)
- No additional setup required!

### Alternative: S3-Compatible Storage

If you prefer S3-compatible storage:

1. **External S3 Service:**
   - Set `useAzureStorage=false` in parameters
   - Provide `awsAccessKeyId`, `awsSecretAccessKey`, `s3BucketName`, `awsRegion`
   - Works immediately

2. **MinIO Gateway (Azure-native S3):**
   - Set `useVolumeMount=false` in parameters
   - Deploy MinIO Container App separately
   - See `AZURE_STORAGE_REVIEW.md` for details


## Scaling

The deployment is configured with:
- **Min replicas**: 1
- **Max replicas**: 10
- **Auto-scaling**: Based on HTTP concurrent requests (100 requests per replica)

You can adjust these in the `main.bicep` file or update after deployment:

```bash
az containerapp update \
  --name outline-app \
  --resource-group outline-rg \
  --min-replicas 2 \
  --max-replicas 20
```

## Monitoring

Logs are automatically sent to Azure Log Analytics. You can view them in:
- Azure Portal → Container Apps → outline-app → Log stream
- Azure Portal → Log Analytics workspaces → outline-logs

## Troubleshooting

### Container won't start
- Check logs: `az containerapp logs show --name outline-app --resource-group outline-rg --follow`
- Verify all secrets are correctly set
- Check database connectivity from Azure

### Database connection errors
- Verify PostgreSQL firewall allows Azure services
- Check connection string format
- Ensure SSL is properly configured (`sslmode=require`)

### Authentication not working
- Verify Azure AD redirect URI matches your Container App FQDN
- Check Azure AD app registration settings
- Verify client ID and secret are correct

## Cost Optimization

- Use **Consumption** plan for Container Apps (pay per use)
- Consider using **Azure Database for PostgreSQL Flexible Server** with burstable tier for development
- Use **Basic** tier for Azure Cache for Redis for development

## Post-Deployment

### View Your Deployment

```bash
# Get Container App URL
az containerapp show \
  --name outline-app \
  --resource-group outline-rg \
  --query "properties.configuration.ingress.fqdn" \
  --output tsv

# View logs
az containerapp logs show \
  --name outline-app \
  --resource-group outline-rg \
  --follow
```

### Configure Custom Domain (Optional)

1. Go to Azure Portal → Container Apps → outline-app → Custom domains
2. Add your custom domain
3. Configure DNS records as shown
4. SSL certificate is automatically managed by Azure

### Update Configuration

To update environment variables or secrets:

```bash
# Update a single environment variable
az containerapp update \
  --name outline-app \
  --resource-group outline-rg \
  --set-env-vars "KEY=VALUE"

# Update multiple environment variables
az containerapp update \
  --name outline-app \
  --resource-group outline-rg \
  --set-env-vars "KEY1=VALUE1" "KEY2=VALUE2"

# Update the URL (important for Outline to generate correct links)
az containerapp update \
  --name outline-app \
  --resource-group outline-rg \
  --set-env-vars "URL=https://your-actual-domain.com"
```

**Important**: The `URL` environment variable tells Outline what domain it's running on. This is used for generating links, email notifications, and OAuth redirects. Make sure to update it after deployment with your actual Container App FQDN or custom domain.

## Next Steps

1. ✅ Deploy the infrastructure (done!)
2. ✅ Update Azure AD redirect URI
3. ✅ Access your Outline instance
4. Configure custom domain (optional)
5. Set up additional authentication providers (optional)

## Support

For more information:
- [Outline Documentation](https://docs.getoutline.com)
- [Azure Container Apps Documentation](https://docs.microsoft.com/azure/container-apps/)
- [Azure Database for PostgreSQL](https://docs.microsoft.com/azure/postgresql/)

