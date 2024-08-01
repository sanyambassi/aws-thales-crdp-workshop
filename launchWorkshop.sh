#!/bin/bash

# Prompt user for password and confirm
while true; do
    read -sp "Enter password for CipherTrust Manager's admin user: " PASSWORD
    echo
    read -sp "Confirm password for the admin user: " PASSWORD_CONFIRM
    echo
    [ "$PASSWORD" = "$PASSWORD_CONFIRM" ] && break
    echo "Passwords do not match. Please try again."
done
echo "Passwords confirmed."

# Define common variables
USER="admin"
NO_SSL_VERIFY="--nosslverify"
STACK_NAME="aws-thales-crdp-workshop"
TEMPLATE_FILE="$PWD/cloud_formation_template.yaml"
REGION="us-east-1"
K8_DEPLOYMENT_FILE="$PWD/k8-deployment.yaml" 

# Create a key pair in AWS in us-east-1
echo "Creating a keypair named ksadmin_cm in AWS us-east-1..."
aws ec2 create-key-pair --key-name ksadmin_cm --query 'KeyMaterial' --region us-east-1 --output text > ksadmin_cm.pem
echo "Created a keypair named ksadmin_cm in AWS us-east-1, and downloaded in the working directory."

# Create CloudFormation stack
echo "Creating CloudFormation stack..."
aws cloudformation create-stack --stack-name $STACK_NAME --template-body file://$TEMPLATE_FILE --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM --region $REGION

# Wait for stack to be created
echo "Waiting for stack to be created..."
aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $REGION
echo "CloudFormation stack created successfully."

# Retrieve the public IP of the CipherTrust Manager
echo "Retrieving public IP of the CipherTrust Manager..."
PUBLIC_IP=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query "Stacks[0].Outputs[?OutputKey=='PublicIPAddress'].OutputValue" --output text)
echo "Public IP: $PUBLIC_IP"

# Retrieve the private IP of the CipherTrust Manager
echo "Retrieving private IP of the CipherTrust Manager..."
PRIVATE_IP=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query "Stacks[0].Outputs[?OutputKey=='InstancePrivateIp'].OutputValue" --output text)
echo "Private IP: $PRIVATE_IP"

# Update k8-deployment.yaml with the private IP
echo "Updating k8 deployment manifest with the private IP..."
sed -i "/name: KEY_MANAGER_HOST/{n;s/value:.*/value: \"$PRIVATE_IP\"/}" $K8_DEPLOYMENT_FILE

# Check if the file has been updated
echo "Verifying if the deployment manifest has been updated..."
grep -A 1 "name: KEY_MANAGER_HOST" $K8_DEPLOYMENT_FILE

# Define the URL with the retrieved public IP
URL="https://$PUBLIC_IP"
KSCTL_URL="$URL/downloads/ksctl_images.zip"

# Retrieve ksctl binaries
echo "Retrieving ksctl binaries..."
wget $KSCTL_URL -O ksctl_images.zip --no-check-certificate
unzip ksctl_images.zip
chmod +x ksctl-linux-amd64
echo "ksctl binaries retrieved and ready to use."

# Change admin user's default password
echo "Changing admin user's default password..."
./ksctl-linux-amd64 changepw -n $PASSWORD -c $PASSWORD --user $USER --password admin --url $URL $NO_SSL_VERIFY
echo "Admin user's password changed successfully."

# Get trial license ID
echo "Retrieving trial license ID..."
TRIAL_ID=$(./ksctl-linux-amd64 licensing trials list --url $URL --user $USER --nosslverify --password $PASSWORD | jq -r '.resources[0].id')

# Activate the trial
echo "Activating the trial license..."
./ksctl-linux-amd64 licensing trials activate --id $TRIAL_ID --url $URL --user $USER --nosslverify --password $PASSWORD
echo "Trial license activated successfully."

# Create character sets
echo "Creating a new character set for All alphabets..."
CHARACTER_SET_ID_1=$(./ksctl-linux-amd64 data-protection character-sets create --name "All Alphabets" --range 0041-005A,0061-007A --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')

# List character sets and extract the required ID for PPol2
CHARACTER_SET_ID_2=$(./ksctl-linux-amd64 data-protection character-sets list --url $URL --user $USER $NO_SSL_VERIFY --password $PASSWORD | jq -r '.resources[] | select(.name == "All digits") | .id')

# Create client profile and extract reg_token
echo "Creating CRDP application on CipherTrust manager and extracting registration token..."
output=$(./ksctl-linux-amd64 data-protection client-profiles create --app-connector-type CRDP --name CRDP_Demo_App --url $URL --user $USER --password "$PASSWORD" $NO_SSL_VERIFY --csr-parameters '{"csr_cn":"crdpviaksctl"}' --configurations '{"log_level":"INFO","heartbeat_interval":30}')
reg_token=$(echo "$output" | jq -r '.reg_token')
echo "CRDP application created and registration token retrieved."

# Update Kubernetes config
echo "Updating Kubernetes configuration..."
CLUSTER_NAME=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query "Stacks[0].Outputs[?OutputKey=='EKSClusterName'].OutputValue" --output text)
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME
echo "Kubernetes configuration updated successfully."

# Create Kubernetes secret with reg_token
echo "Creating Kubernetes secret with registration token..."
kubectl create secret generic regtoken --from-literal=reg_token="$reg_token"
echo "Kubernetes secret created successfully."

# Create user sets
echo "Creating user sets..."
USER_SET_ID_1=$(./ksctl-linux-amd64 data-protection user-sets create --name US_App_Generic_User --users app_generic_user --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
USER_SET_ID_2=$(./ksctl-linux-amd64 data-protection user-sets create --name US_App_Super_User --users app_super_user --users cc_user --users cvv_user --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
USER_SET_ID_3=$(./ksctl-linux-amd64 data-protection user-sets create --name US_App_User_Last4 --users app_user_last4 --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
USER_SET_ID_4=$(./ksctl-linux-amd64 data-protection user-sets create --name US_App_User_First2_Last4 --users app_user_first2_last4 --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
echo "User sets created successfully."

# List masking formats anxtract required IDs
echo "Extracting masking format IDs..."
MASKING_FORMAT_ID_1=$(./ksctl-linux-amd64 data-protection masking-formats list --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY | jq -r '.resources[] | select(.name == "SHOW_LAST_FOUR") | .id')
MASKING_FORMAT_ID_2=$(./ksctl-linux-amd64 data-protection masking-formats list --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY | jq -r '.resources[] | select(.name == "SHOW_FIRST_TWO_LAST_FOUR") | .id')

# Create user set policy JSON file
echo "Creating user set policy JSON file..."
cat <<EOF > user-set-policy.json
[
    {
        "user_set_id": "$USER_SET_ID_2",
        "reveal_type": "Plaintext",
        "error_replacement_value": "",
        "masking_format_id": null
    },
    {
        "user_set_id": "$USER_SET_ID_1",
        "reveal_type": "Ciphertext",
        "error_replacement_value": "",
        "masking_format_id": null
    },
    {
        "user_set_id": "$USER_SET_ID_3",
        "reveal_type": "Masked Value",
        "error_replacement_value": "",
        "masking_format_id": "$MASKING_FORMAT_ID_1"
    },
    {
        "user_set_id": "$USER_SET_ID_4",
        "reveal_type": "Masked Value",
        "error_replacement_value": "",
        "masking_format_id": "$MASKING_FORMAT_ID_2"
    }
]
EOF
echo "User set policy JSON file created successfully."

# Create access policy
echo "Creating access policy..."
ACCESS_POLICY_ID=$(./ksctl-linux-amd64 data-protection access-policies create --name AP01 --default-error-replacement-value "Unauthorized" --default-reveal-type "Error Replacement Value" --jsonfile user-set-policy.json --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
echo "Access policy created successfully."

# Create key JSON file
echo "Creating key JSON file..."
cat <<EOF > createkey.json
{
    "name": "FPEKey",
    "algorithm": "aes",
    "size": 256,
    "undeletable": true,
    "unexportable": false,
    "meta": {
        "ownerId": "local|admin",
        "permissions": {
            "UseKey": ["Application Data Protection Admins", "Application Data Protection Clients"],
            "ReadKey": ["ProtectFile Users", "Application Data Protection Admins", "Application Data Protection Clients"],
            "ExportKey": ["ProtectFile Users", "Application Data Protection Admins", "Application Data Protection Clients"],
            "UploadKey": ["Application Data Protection Admins", "Application Data Protection Clients"],
            "SignWithKey": ["Application Data Protection Admins", "Application Data Protection Clients"],
            "DecryptWithKey": ["Application Data Protection Admins", "Application Data Protection Clients"],
            "EncryptWithKey": ["Application Data Protection Admins", "Application Data Protection Clients"],
            "SignVerifyWithKey": ["Application Data Protection Admins", "Application Data Protection Clients"]
        }
    }
}
EOF
echo "Key JSON file created successfully."

# Create key
echo "Creating key..."
KEY_ID=$(./ksctl-linux-amd64 keys create -j createkey.json --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY | jq -r '.id')
echo "Key created successfully."

# Create protection policies
echo "Creating protection policies..."
./ksctl-linux-amd64 data-protection protection-policies create --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY --algorithm "FPE/AES/UNICODE" --key "FPEKey" --access-policy-name AP01 --character-set-id "$CHARACTER_SET_ID_1" --disable-versioning --tweak 1234567812346578 --tweak-algorithm SHA256 --name PPol1
./ksctl-linux-amd64 data-protection protection-policies create --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY --algorithm "FPE/AES/UNICODE" --key "FPEKey" --access-policy-name AP01 --character-set-id "$CHARACTER_SET_ID_2" --disable-versioning --tweak 1234567812346578 --tweak-algorithm SHA256 --name PPol2
echo "Protection policies created successfully."

# Create K8s resources
echo "Creating Kubernetes resources..."
kubectl apply -f k8-configmap.yaml
kubectl apply -f regcred.yaml
kubectl apply -f $K8_DEPLOYMENT_FILE
echo "Kubernetes resources created successfully."
echo "Geting Kubernetes resources."
kubectl get all

# Wait until the external IP is assigned to the webapp-service
echo "Waiting for the external IP to be assigned to the webapp-service..."
while true; do
    EXTERNAL_IP=$(kubectl get service webapp-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
    echo "Waiting for the external IP to be assigned..."
    sleep 2
done

# Retrieve and print the external IP of the webapp-service
WEBAPP_URL="http://$EXTERNAL_IP"

echo -e "Access the CRDP Demo App at the URL below:"
echo $WEBAPP_URL
echo
echo -e "Access the CipherTrust Manager at the URL below:"
echo $URL
echo
echo "Script execution completed successfully."
