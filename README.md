# AWS Thales CRDP Workshop Setup Script

This repository contains a bash script to automate the deployment and configuration of Thales CipherTrust Manager and Amazon Elastic Kubernetes Service (Amazon EKS) and the associated resources using CloudFormation in AWS.

## Overview

The script performs the following actions:

1. Creates a keypair named "ksadmin_cm" in AWS in us-east-1.
2. Creates a CloudFormation stack based on the provided template.
3. Retrieves the public and private IP addresses of the CipherTrust Manager from the CloudFormation stack.
4. Updates the Kubernetes deployment file with the retrieved private IP address.
5. Downloads and configures the `ksctl` binaries.
6. Changes the default password for the CipherTrust Manager admin user to a user supplied password.
7. Activates the trial license on CipherTrust manager.
8. Creates required resources for CRDP, including user sets, access policies and protection policies, on the CipherTrust manager.
9. Generates and applies Kubernetes configurations, secrets, and resources.
10. Prints the access URLs for the CRDP Demo App and the CipherTrust Manager.

## Prerequisites

Before running the script, ensure you have the following:

1. AWS CLI configured with the appropriate permissions. For required IAM permissions, see `workshop_user_iam_policy.json`.
2. Kubernetes CLI (`kubectl`) installed and configured.
3. `jq` command-line JSON processor installed.
4. `git` CLI installed.

## Usage

1. Clone this repository:
    ```sh
    git clone https://github.com/sanyambassi/aws-thales-crdp-workshop.git
    cd aws-thales-crdp-workshop
    ```

2. Ensure the `cloud_formation_template.yaml` and `k8-deployment.yaml` files are present in the working directory.

3. Make the script executable:
    ```sh
    chmod +x launchWorkshop.sh
    ```

4. Run the script:
    ```sh
    ./launchWorkshop.sh
    ```

## Script Breakdown

### Password Prompt

The script prompts the user to enter and confirm the password for the CipherTrust Manager admin user.

### KeyPair Creation

The script creates a key pair in AWS to be used for logging into the CipherTrust manager and Kubernetes nodes.

### CloudFormation Stack Creation

The script creates a CloudFormation stack using the provided template file (`cloud_formation_template.yaml`) and waits for its completion.

### Retrieve IP Addresses

The script retrieves the public and private IP addresses of the CipherTrust Manager from the CloudFormation stack outputs.

### Update Kubernetes Deployment File

The script updates the `k8-deployment.yaml` file with the retrieved private IP address of the CipherTrust Manager.

### Download and Configure `ksctl` Binaries

The script downloads and configures the `ksctl` binaries needed to interact with the CipherTrust Manager.

### Change Admin User's Password

The script changes the default password for the CipherTrust Manager admin user to the password provided by the user.

### Activate Trial License

The script retrieves and activates a trial license for the CipherTrust Manager.

### Create Character Sets and User Sets

The script creates necessary character sets and user sets on the CipherTrust Manager to be used with CRDP.

### Apply Kubernetes Configurations and Resources

The script updates the Kubernetes configuration, creates a secret with the registration token, and applies the provided Kubernetes configurations and resources. This creates 2 application pods - one for mysql and another pods with a frontend webapp with Thales CRDP (Ciphertrust RESTful Data Protection) container as sidecar. 

### Retrieve External IP Address

The script waits for the external IP address to be assigned to the Kubernetes service and prints the access URLs for the CRDP Demo App and the CipherTrust Manager.

## Troubleshooting

If you encounter any issues while running the script, check the following:

1. Ensure your AWS CLI is configured correctly. Verify your configured IAM user with this command - "`aws sts get-caller-identity`"
2. Verify that `kubectl` is installed and configured.
3. Make sure the `jq` tool is installed on your system.
4. Check the CloudFormation and Kubernetes logs for any errors.

## Contributing

If you would like to contribute to this project, please open an issue or submit a pull request with your changes.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
