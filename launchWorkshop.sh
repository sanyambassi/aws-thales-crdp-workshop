#!/bin/bash
echo

# Prompt user for CloudFormation stack name
read -p "Enter the name for the CloudFormation stack to create: " STACK_NAME
echo

# Prompt user for key pair name
read -p "Enter the name for the AWS key pair to create for this workshop: " KEY_PAIR_NAME
echo

# Prompt user for password and confirm
while true; do
    read -sp "Create/Enter a new password for CipherTrust Manager's admin user: " PASSWORD
    echo
    read -sp "Confirm password: " PASSWORD_CONFIRM
    echo
    [ "$PASSWORD" = "$PASSWORD_CONFIRM" ] && break
    echo "Passwords do not match. Please try again."
done
echo "Passwords match."
echo

# Define common variables
USER="admin"
NO_SSL_VERIFY="--nosslverify"
TEMPLATE_FILE="$PWD/cloud_formation_template.yaml"
REGION="us-east-1"
K8_DEPLOYMENT_FILE="$PWD/k8-deployment.yaml" 
JMX_FILE="$PWD/crdp-jmeter-metrics.jmx"
JMX_SCRIPT="$PWD/create_jmx_files.sh"

echo

# Create a key pair in AWS in us-east-1
echo "Creating a keypair named $KEY_PAIR_NAME in AWS us-east-1..."
aws ec2 create-key-pair --key-name $KEY_PAIR_NAME --query 'KeyMaterial' --region us-east-1 --output text > $KEY_PAIR_NAME.pem
echo "Created a keypair named $KEY_PAIR_NAME in AWS us-east-1, and saved in the current working directory."
echo

# Create CloudFormation stack
echo "Creating CloudFormation stack..."
aws cloudformation create-stack --stack-name $STACK_NAME --template-body file://$TEMPLATE_FILE --parameters ParameterKey=KeyPairName,ParameterValue=$KEY_PAIR_NAME --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM --region $REGION
echo
# Wait for stack to be created
echo "Waiting for stack to be created..."
aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $REGION
echo "CloudFormation stack created successfully."
echo

# Retrieve the public IP of the CipherTrust Manager
echo "Retrieving public IP of the CipherTrust Manager..."
PUBLIC_IP=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query "Stacks[0].Outputs[?OutputKey=='PublicIPAddress'].OutputValue" --output text)
echo "Public IP: $PUBLIC_IP"
echo

# Retrieve the private IP of the CipherTrust Manager
echo "Retrieving private IP of the CipherTrust Manager..."
PRIVATE_IP=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query "Stacks[0].Outputs[?OutputKey=='InstancePrivateIp'].OutputValue" --output text)
echo "Private IP: $PRIVATE_IP"
echo

# Update k8-deployment.yaml with the private IP
echo "Updating k8 deployment manifest with the private IP..."
sed -i "/name: KEY_MANAGER_HOST/{n;s/value:.*/value: \"$PRIVATE_IP\"/}" $K8_DEPLOYMENT_FILE
echo
# Check if the file has been updated
echo "Verifying if the deployment manifest has been updated..."
grep -A 1 "name: KEY_MANAGER_HOST" $K8_DEPLOYMENT_FILE
echo

# Define the URL with the retrieved public IP
URL="https://$PUBLIC_IP"
KSCTL_URL="$URL/downloads/ksctl_images.zip"
echo
# Retrieve ksctl binaries
echo "Retrieving ksctl binaries..."
wget $KSCTL_URL -O ksctl_images.zip --no-check-certificate
unzip ksctl_images.zip
chmod +x ksctl-linux-amd64
echo "ksctl binaries retrieved and ready to use."
echo

# Change admin user's default password
echo "Changing admin user's default password..."
./ksctl-linux-amd64 changepw -n $PASSWORD -c $PASSWORD --user $USER --password admin --url $URL $NO_SSL_VERIFY
echo "Admin user's password changed successfully."
echo

# Get trial license ID
echo "Retrieving trial license ID..."
TRIAL_ID=$(./ksctl-linux-amd64 licensing trials list --url $URL --user $USER --nosslverify --password $PASSWORD | jq -r '.resources[0].id')
echo

# Activate the trial
echo "Activating the trial license..."
./ksctl-linux-amd64 licensing trials activate --id $TRIAL_ID --url $URL --user $USER --nosslverify --password $PASSWORD
echo "Trial license activated successfully."
echo

# Create character sets
echo "Creating a new character set for All alphabets..."
CHARACTER_SET_ID_1=$(./ksctl-linux-amd64 data-protection character-sets create --name "All Alphabets" --range 0041-005A,0061-007A --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
echo

# List character sets and extract the ID for All digits character set
CHARACTER_SET_ID_2=$(./ksctl-linux-amd64 data-protection character-sets list --url $URL --user $USER $NO_SSL_VERIFY --password $PASSWORD | jq -r '.resources[] | select(.name == "All digits") | .id')
echo

# Create client profile and extract reg_token
echo "Creating CRDP application on CipherTrust manager and extracting registration token..."
output=$(./ksctl-linux-amd64 data-protection client-profiles create --app-connector-type CRDP --name CRDP_Demo_App --url $URL --user $USER --password "$PASSWORD" $NO_SSL_VERIFY --csr-parameters '{"csr_cn":"crdpviaksctl"}' --configurations '{"log_level":"INFO","heartbeat_interval":30}')
reg_token=$(echo "$output" | jq -r '.reg_token')
echo "CRDP application created and registration token retrieved."
echo

# Update Kubernetes config
echo "Updating Kubernetes configuration..."
CLUSTER_NAME=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query "Stacks[0].Outputs[?OutputKey=='EKSClusterName'].OutputValue" --output text)
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME
echo "Kubernetes configuration updated successfully."
echo

# Create Kubernetes secret with the registration token
echo "Creating Kubernetes secret with registration token..."
kubectl create secret generic regtoken --from-literal=reg_token="$reg_token"
echo "Kubernetes secret created successfully."
echo

# Create user sets
echo "Creating user sets..."
USER_SET_ID_1=$(./ksctl-linux-amd64 data-protection user-sets create --name US_App_Generic_User --users app_generic_user --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
USER_SET_ID_2=$(./ksctl-linux-amd64 data-protection user-sets create --name US_App_Authorized_Users --users app_super_user --users cc_user --users cvv_user --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
USER_SET_ID_3=$(./ksctl-linux-amd64 data-protection user-sets create --name US_App_User_Last4 --users app_user_last4 --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
USER_SET_ID_4=$(./ksctl-linux-amd64 data-protection user-sets create --name US_App_User_First2_Last4 --users app_user_first2_last4 --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
echo "User sets created successfully."
echo

# List masking formats and extract required IDs
echo "Extracting masking format IDs..."
MASKING_FORMAT_ID_1=$(./ksctl-linux-amd64 data-protection masking-formats list --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY | jq -r '.resources[] | select(.name == "SHOW_LAST_FOUR") | .id')
MASKING_FORMAT_ID_2=$(./ksctl-linux-amd64 data-protection masking-formats list --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY | jq -r '.resources[] | select(.name == "SHOW_FIRST_TWO_LAST_FOUR") | .id')
echo

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
echo

# Create access policy
echo "Creating access policy..."
ACCESS_POLICY_ID=$(./ksctl-linux-amd64 data-protection access-policies create --name AP01 --default-error-replacement-value "Unauthorized" --default-reveal-type "Error Replacement Value" --jsonfile user-set-policy.json --user $USER --password $PASSWORD $NO_SSL_VERIFY --url $URL | jq -r '.id')
echo "Access policy created successfully."
echo

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
echo

# Create key
echo "Creating key..."
KEY_ID=$(./ksctl-linux-amd64 keys create -j createkey.json --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY | jq -r '.id')
echo "Key created successfully."
echo

# Create protection policies
echo "Creating protection policies..."
./ksctl-linux-amd64 data-protection protection-policies create --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY --algorithm "FPE/AES/UNICODE" --key "FPEKey" --access-policy-name AP01 --character-set-id "$CHARACTER_SET_ID_1" --disable-versioning --tweak 1234567812346578 --tweak-algorithm SHA256 --name PPol1
./ksctl-linux-amd64 data-protection protection-policies create --url $URL --user $USER --password $PASSWORD $NO_SSL_VERIFY --algorithm "FPE/AES/UNICODE" --key "FPEKey" --access-policy-name AP01 --character-set-id "$CHARACTER_SET_ID_2" --disable-versioning --tweak 1234567812346578 --tweak-algorithm SHA256 --name PPol2
echo "Protection policies created successfully."
echo

# Create K8s resources
echo "Creating Kubernetes resources..."
kubectl apply -f k8-configmap.yaml
kubectl apply -f regcred.yaml
kubectl apply -f $K8_DEPLOYMENT_FILE
echo "Kubernetes resources created successfully."
echo
echo "Getting Kubernetes resources."
kubectl get all
echo

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
echo "External IP assigned to the webapp-service..."
echo

# Wait for crdp-container and jmeter to be ready
echo "Waiting for crdp-container and jmeter containers to be ready..."
while true; do
    CRDP_READY=$(kubectl get pods -l app=webapp -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="crdp-container")].ready}')
    JMETER_READY=$(kubectl get pods -l app=webapp -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="jmeter")].ready}')
    if [ "$CRDP_READY" = "true" ] && [ "$JMETER_READY" = "true" ]; then
        break
    fi
    echo "Waiting for crdp-container and jmeter to be ready..."
    sleep 2
done
echo "Ready..."
echo

# Get the webapp pod name
WEBAPP_POD_NAME=$(kubectl get pods -l app=webapp -o jsonpath='{.items[0].metadata.name}')
echo

# Copy the JMX file to the JMeter container
echo "Copying JMX file to the JMeter container..."
kubectl cp $JMX_FILE $WEBAPP_POD_NAME:/jmeter/crdp-jmeter-metrics.jmx -c jmeter 2>/dev/null
echo "JMX file copied successfully."
echo

# Copy the JMX script to the JMeter container
echo "Copying JMX script to the JMeter container..."
kubectl cp $JMX_SCRIPT $WEBAPP_POD_NAME:/jmeter/create_jmx_files.sh -c jmeter 2>/dev/null
echo "JMX script copied successfully."
echo

# Execute the JMeter test
echo "Executing performance tests..."
kubectl exec -it $WEBAPP_POD_NAME -c jmeter -- /bin/bash -c "cd /jmeter && chmod +x ./create_jmx_files.sh && ./create_jmx_files.sh"

# Run the JMeter tests sequentially
echo "Initializing... Takes about 2 minutes"
kubectl exec -it $WEBAPP_POD_NAME -c jmeter -- /bin/bash -c "cd /jmeter && jmeter -n -t crdp-jmeter-metrics-100.jmx -l results100.jtl > /jmeter/out1.txt"
echo "10k transactions completed."
kubectl exec -it $WEBAPP_POD_NAME -c jmeter -- /bin/bash -c "cd /jmeter && jmeter -n -t crdp-jmeter-metrics-200.jmx -l results200.jtl > /jmeter/out2.txt"
echo "20k transactions completed."
kubectl exec -it $WEBAPP_POD_NAME -c jmeter -- /bin/bash -c "cd /jmeter && jmeter -n -t crdp-jmeter-metrics-300.jmx -l results300.jtl > /jmeter/out3.txt"
echo "30k transactions completed."
kubectl exec -it $WEBAPP_POD_NAME -c jmeter -- /bin/bash -c "cd /jmeter && jmeter -n -t crdp-jmeter-metrics-400.jmx -l results400.jtl > /jmeter/out4.txt"
echo "40k transactions completed."
kubectl exec -it $WEBAPP_POD_NAME -c jmeter -- /bin/bash -c "cd /jmeter && jmeter -n -t crdp-jmeter-metrics-500.jmx -l results500.jtl > /jmeter/out5.txt"
echo "50k transactions completed."

# Copy the result files back to the local machine
kubectl cp $WEBAPP_POD_NAME:/jmeter/out1.txt -c jmeter out1.txt
kubectl cp $WEBAPP_POD_NAME:/jmeter/out2.txt -c jmeter out2.txt
kubectl cp $WEBAPP_POD_NAME:/jmeter/out3.txt -c jmeter out3.txt
kubectl cp $WEBAPP_POD_NAME:/jmeter/out4.txt -c jmeter out4.txt
kubectl cp $WEBAPP_POD_NAME:/jmeter/out5.txt -c jmeter out5.txt

# Ensure the /jmeter directory exists in the pod
kubectl exec -it $WEBAPP_POD_NAME -- /bin/bash -c "mkdir -p /jmeter"

# Copy the result files back to the pod
kubectl cp out1.txt $WEBAPP_POD_NAME:/jmeter/out1.txt 2>/dev/null
kubectl cp out2.txt $WEBAPP_POD_NAME:/jmeter/out2.txt 2>/dev/null
kubectl cp out3.txt $WEBAPP_POD_NAME:/jmeter/out3.txt 2>/dev/null
kubectl cp out4.txt $WEBAPP_POD_NAME:/jmeter/out4.txt 2>/dev/null
kubectl cp out5.txt $WEBAPP_POD_NAME:/jmeter/out5.txt 2>/dev/null

#Delete test results
rm out*.txt
echo -e "\e[32mPerformance tests executed successfully.\e[0m"
echo

# Retrieve and print information about how to access the demo.
WEBAPP_URL="http://$EXTERNAL_IP"
echo
echo -e "\e[32mAccess the CRDP Demo App at the URL below (it can take up to 60 seconds for the service to come online):\e[0m"
echo $WEBAPP_URL
echo
echo -e "\e[32mAccess the CipherTrust Manager at the URL below:\e[0m"
echo $URL
echo
echo -e "\e[32mWorkshop launched successfully.\e[0m"
