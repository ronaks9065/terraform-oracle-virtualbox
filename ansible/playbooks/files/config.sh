# Updated config.sh
# Log file path
LOG_FILE="/var/log/k3s_install.log"
# GitHub repository URL
REPO_URL="https://github.com/ronaks9065/thryvo-manifests.git"
# List of deployment paths
DEPLOYMENT_PATHS=(
  "databases/mysql.yaml"
  "databases/mongodb.yaml"
  "databases/neo4j.yaml"
  "backend/pa-leavemodule/deployment.yaml"
  "backend/pa-baseline/deployment.yaml"
  "backend/bff/deployment.yaml"
  "backend/pa-authz/deployment.yaml"
  "frontend/thryvo-ui/deployment.yaml"
  # Add more paths as needed
)
# Certificate file paths
CERT_DIR="/tmp"
PRIVATE_KEY="$CERT_DIR/private.key"
CERTIFICATE="$CERT_DIR/certificate.crt"
PRIVATE_RSA_KEY="$CERT_DIR/private-rsa.key"

# ACR Configuration
ACR_NAME="caxdevacrpa0"
ACR_RESOURCE_GROUP="cax_peopleanalytics_rg"