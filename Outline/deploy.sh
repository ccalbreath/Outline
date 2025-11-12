#!/bin/bash

# Azure Container Apps Deployment Script for Outline
# This script deploys Outline to Azure Container Apps using your own PostgreSQL database

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
RESOURCE_GROUP="outline-rg"
LOCATION="centralus"
CONTAINER_APP_NAME="outline-app"
ENVIRONMENT_NAME="outline-env"
PARAMETERS_FILE="azuredeploy.parameters.json"

echo -e "${GREEN}Starting Azure Container Apps deployment for Outline...${NC}"

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo -e "${RED}Azure CLI is not installed. Please install it from https://aka.ms/InstallAzureCLI${NC}"
    exit 1
fi

# Check if logged in
if ! az account show &> /dev/null; then
    echo -e "${YELLOW}Not logged in to Azure. Please run 'az login'${NC}"
    exit 1
fi

# Create resource group if it doesn't exist
echo -e "${GREEN}Creating resource group...${NC}"
az group create --name $RESOURCE_GROUP --location $LOCATION || true

# Deploy using Bicep
echo -e "${GREEN}Deploying infrastructure with Bicep...${NC}"
echo -e "${YELLOW}This may take 10-15 minutes. Please wait...${NC}"
DEPLOYMENT_NAME="outline-deployment-$(date +%s)"

echo -e "${YELLOW}Starting deployment: ${DEPLOYMENT_NAME}${NC}"
echo -e "${YELLOW}You can monitor progress in Azure Portal or with:${NC}"
echo -e "  az deployment group show --resource-group $RESOURCE_GROUP --name $DEPLOYMENT_NAME"

# Run deployment
echo -e "${YELLOW}Starting deployment (this may take 10-15 minutes)...${NC}"
echo -e "${YELLOW}Note: You can monitor progress in Azure Portal${NC}"

# Try deployment with --no-wait first (faster, but may have CLI issues)
echo -e "${YELLOW}Attempting async deployment...${NC}"
if az deployment group create \
  --resource-group $RESOURCE_GROUP \
  --name $DEPLOYMENT_NAME \
  --template-file main.bicep \
  --parameters @$PARAMETERS_FILE \
  --no-wait >/dev/null 2>&1; then
  
  echo -e "${GREEN}Deployment started successfully!${NC}"
  echo -e "${YELLOW}Waiting for deployment to complete...${NC}"
  
  # Wait for deployment to complete
  while true; do
    STATE=$(az deployment group show \
      --resource-group $RESOURCE_GROUP \
      --name $DEPLOYMENT_NAME \
      --query "properties.provisioningState" \
      --output tsv 2>/dev/null)
    
    if [ "$STATE" = "Succeeded" ]; then
      echo -e "${GREEN}Bicep deployment completed successfully!${NC}"
      break
    elif [ "$STATE" = "Failed" ] || [ "$STATE" = "Canceled" ]; then
      echo -e "${RED}Deployment failed with state: ${STATE}${NC}"
      echo -e "${YELLOW}Error details:${NC}"
      az deployment group show \
        --resource-group $RESOURCE_GROUP \
        --name $DEPLOYMENT_NAME \
        --query "properties.error" \
        --output json
      exit 1
    elif [ -n "$STATE" ]; then
      echo -e "${YELLOW}Deployment in progress... (State: ${STATE})${NC}"
      sleep 10
    else
      # State might be empty if deployment just started, wait a bit
      sleep 5
    fi
  done
else
  # Fallback: try synchronous deployment (slower but more reliable)
  echo -e "${YELLOW}Async deployment failed, trying synchronous deployment...${NC}"
  echo -e "${YELLOW}This will take longer but is more reliable...${NC}"
  
  if ! az deployment group create \
    --resource-group $RESOURCE_GROUP \
    --name $DEPLOYMENT_NAME \
    --template-file main.bicep \
    --parameters @$PARAMETERS_FILE; then
    echo -e "${RED}Deployment failed!${NC}"
    echo -e "${YELLOW}Check the error above or Azure Portal for details.${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}Bicep deployment completed successfully!${NC}"
fi

# Storage mount configuration is now handled by the Bicep deployment script
# The deployment script resource ensures storage is configured before Container App is created
echo -e "${GREEN}Storage mount configuration handled by Bicep deployment script${NC}"

# Get the FQDN
FQDN=$(az containerapp show \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --query "properties.configuration.ingress.fqdn" \
  --output tsv)

# Update the URL environment variable to match the actual FQDN
# This is critical for CSP (Content Security Policy) to work correctly
echo -e "${GREEN}Updating URL environment variable to match Container App FQDN...${NC}"
az containerapp update \
  --name $CONTAINER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --set-env-vars "URL=https://${FQDN}" >/dev/null 2>&1

if [ $? -eq 0 ]; then
  echo -e "${GREEN}URL environment variable updated successfully!${NC}"
else
  echo -e "${YELLOW}Warning: Failed to update URL environment variable automatically.${NC}"
  echo -e "${YELLOW}Please update it manually:${NC}"
  echo -e "  az containerapp update --name $CONTAINER_APP_NAME --resource-group $RESOURCE_GROUP --set-env-vars \"URL=https://${FQDN}\""
fi

echo -e "${GREEN}Deployment complete!${NC}"
echo -e "${GREEN}Your Outline app is available at: https://${FQDN}${NC}"
echo -e "${YELLOW}Don't forget to:${NC}"
echo -e "  1. Update your Azure AD redirect URI to: https://${FQDN}/auth/azure.callback"
echo -e "  2. Wait a few moments for the Container App to restart with the updated URL"

