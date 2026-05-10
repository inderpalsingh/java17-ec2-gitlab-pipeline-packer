#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -n, --name NAME           Instance name (default: java-app-instance)"
    echo "  -t, --instance-type TYPE  Instance type (default: t2.micro)"
    echo "  -a, --ami-id ID          AMI ID to use (default: latest java-app AMI)"
    echo "  -k, --key-name NAME      SSH key pair name (required)"
    echo "  -s, --security-group ID  Security group ID or name"
    echo "  -p, --profile PROFILE    AWS profile to use"
    echo "  -r, --region REGION      AWS region"
    echo "  -h, --help               Display this help message"
    exit 1
}

# Default values
INSTANCE_NAME="java-app-instance"
INSTANCE_TYPE="t2.micro"
AMI_ID=""
KEY_NAME=""
SECURITY_GROUP=""
AWS_PROFILE=""
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)
            INSTANCE_NAME="$2"
            shift 2
            ;;
        -t|--instance-type)
            INSTANCE_TYPE="$2"
            shift 2
            ;;
        -a|--ami-id)
            AMI_ID="$2"
            shift 2
            ;;
        -k|--key-name)
            KEY_NAME="$2"
            shift 2
            ;;
        -s|--security-group)
            SECURITY_GROUP="$2"
            shift 2
            ;;
        -p|--profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Set AWS CLI options
AWS_OPTS="--region $AWS_REGION"
if [ -n "$AWS_PROFILE" ]; then
    AWS_OPTS="$AWS_OPTS --profile $AWS_PROFILE"
fi

# Validate required parameters
if [ -z "$KEY_NAME" ]; then
    echo -e "${RED}Error: SSH key name is required${NC}"
    usage
fi

echo -e "${GREEN}=== Creating EC2 Instance ===${NC}"

# Get latest AMI if not specified
if [ -z "$AMI_ID" ]; then
    echo -e "${YELLOW}Finding latest Java application AMI...${NC}"

    # Try to get from SSM first
    if aws ssm get-parameter --name "/java-app/latest-ami" $AWS_OPTS &>/dev/null; then
        AMI_ID=$(aws ssm get-parameter \
            --name "/java-app/latest-ami" \
            --query "Parameter.Value" \
            --output text \
            $AWS_OPTS)
        echo -e "${GREEN}Using AMI from SSM: ${AMI_ID}${NC}"
    else
        # Get latest AMI from self-owned images
        AMI_ID=$(aws ec2 describe-images \
            --owners self \
            --filters "Name=name,Values=java-app-*" \
            --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
            --output text \
            $AWS_OPTS)

        if [ "$AMI_ID" = "None" ] || [ -z "$AMI_ID" ]; then
            echo -e "${RED}No Java application AMI found. Please run build-ami.sh first${NC}"
            exit 1
        fi
        echo -e "${GREEN}Using latest AMI: ${AMI_ID}${NC}"
    fi
fi

# Create or get security group
if [ -z "$SECURITY_GROUP" ]; then
    SECURITY_GROUP_NAME="java-app-sg"
    echo -e "${YELLOW}Checking for security group: ${SECURITY_GROUP_NAME}${NC}"

    # Check if security group exists
    SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        $AWS_OPTS)

    if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
        echo -e "${YELLOW}Creating security group: ${SECURITY_GROUP_NAME}${NC}"

        SG_ID=$(aws ec2 create-security-group \
            --group-name "$SECURITY_GROUP_NAME" \
            --description "Security group for Java application" \
            --query 'GroupId' \
            --output text \
            $AWS_OPTS)

        # Add SSH rule
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 \
            --description "SSH access" \
            $AWS_OPTS

        # Add HTTP rule for application
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 8080 \
            --cidr 0.0.0.0/0 \
            --description "HTTP access" \
            $AWS_OPTS

        echo -e "${GREEN}Created security group: ${SG_ID}${NC}"
    else
        echo -e "${GREEN}Using existing security group: ${SG_ID}${NC}"
    fi
    SECURITY_GROUP="$SG_ID"
fi

# Check if key pair exists
echo -e "${YELLOW}Checking key pair: ${KEY_NAME}${NC}"
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" $AWS_OPTS &>/dev/null; then
    echo -e "${RED}Key pair '${KEY_NAME}' not found${NC}"
    exit 1
fi

# Create user data script for instance initialization
cat > /tmp/user-data.sh << 'EOF'
#!/bin/bash
# Start the application service if not already running
if systemctl is-active --quiet application; then
    echo "Application already running"
else
    systemctl start application
fi

# Wait for application to be ready
for i in {1..30}; do
    if curl -f http://localhost:8080/health; then
        echo "Application is healthy"
        break
    fi
    sleep 2
done
EOF

# Launch instance
echo -e "${YELLOW}Launching EC2 instance...${NC}"
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP" \
    --user-data "file:///tmp/user-data.sh" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=CreatedBy,Value=create-instance-script},{Key=AppVersion,Value=java17}]" \
    --query 'Instances[0].InstanceId' \
    --output text \
    $AWS_OPTS)

if [ $? -ne 0 ] || [ -z "$INSTANCE_ID" ]; then
    echo -e "${RED}Failed to create instance${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Instance created: ${INSTANCE_ID}${NC}"

# Wait for instance to be running
echo -e "${YELLOW}Waiting for instance to be in running state...${NC}"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" $AWS_OPTS

# Get instance details
echo -e "${YELLOW}Getting instance details...${NC}"
INSTANCE_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text \
    $AWS_OPTS)

INSTANCE_STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text \
    $AWS_OPTS)

echo -e "${GREEN}=== Instance Details ===${NC}"
echo -e "Instance ID: ${GREEN}$INSTANCE_ID${NC}"
echo -e "Public IP: ${GREEN}$INSTANCE_IP${NC}"
echo -e "Instance Type: ${GREEN}$INSTANCE_TYPE${NC}"
echo -e "State: ${GREEN}$INSTANCE_STATE${NC}"
echo -e "Key Name: ${GREEN}$KEY_NAME${NC}"
echo -e "Security Group: ${GREEN}$SECURITY_GROUP${NC}"

# Wait for application to be ready
echo -e "${YELLOW}Waiting for application to be ready...${NC}"
RETRIES=30
for i in $(seq 1 $RETRIES); do
    if curl -s -f "http://${INSTANCE_IP}:8080/health" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Application is ready!${NC}"
        echo -e "${GREEN}Access your application at: http://${INSTANCE_IP}:8080${NC}"
        break
    elif [ $i -eq $RETRIES ]; then
        echo -e "${RED}Application health check failed after $RETRIES attempts${NC}"
        echo -e "${YELLOW}You can still SSH into the instance: ssh -i ${KEY_NAME}.pem ec2-user@${INSTANCE_IP}${NC}"
    else
        echo -n "."
        sleep 5
    fi
done

# Save instance info to file
cat > "$(dirname "$0")/instance-info.txt" << EOF
Instance ID: $INSTANCE_ID
Public IP: $INSTANCE_IP
Instance Type: $INSTANCE_TYPE
AMI ID: $AMI_ID
Key Name: $KEY_NAME
Security Group: $SECURITY_GROUP
Created: $(date)
EOF

echo -e "${GREEN}Instance info saved to instance-info.txt${NC}"

# Cleanup
rm -f /tmp/user-data.sh

echo -e "${GREEN}=== Instance Creation Complete ===${NC}"

# Optional: Add to SSH config
if [ -d ~/.ssh ]; then
    echo -e "${YELLOW}Add to SSH config? (y/n)${NC}"
    read -r ADD_TO_SSH_CONFIG
    if [[ "$ADD_TO_SSH_CONFIG" =~ ^[Yy]$ ]]; then
        cat >> ~/.ssh/config << EOF

Host $INSTANCE_NAME
    HostName $INSTANCE_IP
    User ec2-user
    IdentityFile ~/.ssh/${KEY_NAME}.pem
EOF
        echo -e "${GREEN}Added SSH config for '${INSTANCE_NAME}'${NC}"
    fi
fi