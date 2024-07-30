#!/bin/bash

# Prompt user for password
read -sp "Enter password for admin user: " PASSWORD
echo

# Define common variables
USER="admin"
NO_SSL_VERIFY="--nosslverify"
STACK_NAME="aws-thales-crdp-workshop"
TEMPLATE_FILE="/home/cloudshell-user/crdp-workshop/all_res.yaml" # Update this path to your CloudFormation template
REGION="us-east-1"

# Create CloudFormation stack
aws cloudformation create-stack --stack-name $STACK_NAME --template-body file://$TEMPLATE_FILE

# Wait for stack to be created
echo "Waiting for stack to be created..."
aws cloudformation wait stack-create-complete --stack-name $STACK_NAME

# Retrieve the public IP of the EC2 instance
PUBLIC_IP=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query  "Stacks[0].Outputs[?OutputKey=='PublicIPAddress'].OutputValue" --output text)

# Define the URL with the retrieved public IP
URL="https://$PUBLIC_IP"
KSCTL_URL="$URL/downloads/ksctl_images.zip"

# Retrieve ksctl binaries
wget $KSCTL_URL -O ksctl_images.zip --no-check-certificate
unzip ksctl_images.zip
chmod +x ksctl-linux-amd64

# Change admin user's default password
./ksctl-linux-amd64 changepw -n $PASSWORD -c $PASSWORD --user $USER --password admin --url $URL  $NO_SSL_VERIFY

# Create character sets
CHARACTER_SET_ID_1=$(./ksctl-linux-amd64 data-protection character-sets create --name "all alpha" --range 0041-005A,0061-007A --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')

# List character sets and extract the required ID for PPol2
CHARACTER_SET_ID_2=$(./ksctl-linux-amd64 data-protection character-sets list --url $URL --user $USER $NO_SSL_VERIFY --password $PASSWORD | jq -r '.resources[] | select(.name == "All digits") | .id')

# Create client profile and extract reg_token
output=$(./ksctl-linux-amd64 data-protection client-profiles create --app-connector-type CRDP --name CRDP_Demo_1 --url $URL --user $USER --password "$PASSWORD" $NO_SSL_VERIFY --csr-parameters '{"csr_cn":"crdpviaksctl"}' --configurations '{"log_level":"INFO","heartbeat_interval":30}')

reg_token=$(echo "$output" | jq -r '.reg_token')

# Update Kubernetes config
CLUSTER_NAME=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue" --output text)
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME

# Create Kubernetes secret with reg_token
kubectl create secret generic regtoken --from-literal=reg_token="$reg_token"

# Create user sets
USER_SET_ID_1=$(./ksctl-linux-amd64 data-protection user-sets create --name US_App_Generic_User --users app_generic_user --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
USER_SET_ID_2=$(./ksctl-linux-amd64 data-protection user-sets create --name US_App_Super_User --users app_super_user --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
USER_SET_ID_3=$(./ksctl-linux-amd64 data-protection user-sets create --name US_App_User_Last4 --users app_user_last4 --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
USER_SET_ID_4=$(./ksctl-linux-amd64 data-protection user-sets create --name US_App_User_Last6 --users app_user_last6 --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')

# List masking formats and extract required IDs
MASKING_FORMAT_ID_1=$(./ksctl-linux-amd64 data-protection masking-formats list --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY | jq -r '.resources[] | select(.name == "SHOW_LAST_FOUR") | .id')
MASKING_FORMAT_ID_2=$(./ksctl-linux-amd64 data-protection masking-formats list --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY | jq -r '.resources[] | select(.name == "SHOW_FIRST_TWO_LAST_FOUR") | .id')

# Create user set policy JSON file
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

# Create access policy
ACCESS_POLICY_ID=$(./ksctl-linux-amd64 data-protection access-policies create --name AP01 --default-error-replacement-value "Unauthorized" --default-reveal-type "Error Replacement Value" --jsonfile user-set-policy.json --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')

# Create key JSON file
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

# Create key
KEY_ID=$(./ksctl-linux-amd64 keys create -j createkey.json --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY | jq -r '.id')

# Create protection policies
./ksctl-linux-amd64 data-protection protection-policies create --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY --algorithm "FPE/FF3-1/UNICODE" --key "FPEKey" --access-policy-name AP01 --character-set-id "$CHARACTER_SET_ID_1" --disable-versioning --tweak 1234567812346578 --tweak-algorithm SHA256 --name PPol1
./ksctl-linux-amd64 data-protection protection-policies create --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY --algorithm "FPE/FF3-1/UNICODE" --key "FPEKey" --access-policy-name AP01 --character-set-id "$CHARACTER_SET_ID_2" --disable-versioning --tweak 1234567812346578 --tweak-algorithm SHA256 --name PPol2

echo "Script execution completed."

