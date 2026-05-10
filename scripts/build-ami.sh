#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Building Java Application AMI ===${NC}"

# Variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKER_DIR="$PROJECT_ROOT/packer"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
AMI_NAME="java-app-${TIMESTAMP}"

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

# Check if packer is installed
if ! command -v packer &> /dev/null; then
    echo -e "${RED}Packer is not installed. Installing...${NC}"
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
        sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
        sudo apt-get update && sudo apt-get install packer
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        brew tap hashicorp/tap
        brew install hashicorp/tap/packer
    fi
fi

# Check if AWS CLI is configured
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}AWS CLI not configured. Please run 'aws configure' first${NC}"
    exit 1
fi

# Check if Java 17 is available locally
if ! command -v java &> /dev/null || [[ $(java -version 2>&1 | grep -i version | cut -d'"' -f2 | cut -d'.' -f1) -lt 17 ]]; then
    echo -e "${YELLOW}Java 17 not found locally. Will use Amazon Linux's Java 17${NC}"
fi

# Build the Java application
echo -e "${YELLOW}Building Java application...${NC}"
cd "$PROJECT_ROOT"

# Check if using Gradle or Maven
if [ -f "gradlew" ]; then
    echo "Using Gradle wrapper"
    ./gradlew clean build -x test
    JAR_PATH="build/libs/*.jar"
elif [ -f "build.gradle" ]; then
    echo "Using Gradle"
    gradle clean build -x test
    JAR_PATH="build/libs/*.jar"
elif [ -f "pom.xml" ]; then
    echo "Using Maven"
    mvn clean package -DskipTests
    JAR_PATH="target/*.jar"
else
    echo -e "${RED}No build file found (build.gradle or pom.xml)${NC}"
    exit 1
fi

# Check if JAR was built
if [ -z "$(ls $JAR_PATH 2>/dev/null)" ]; then
    echo -e "${RED}Failed to build JAR file${NC}"
    exit 1
fi

# Copy JAR to packer directory
echo -e "${YELLOW}Copying JAR to Packer directory...${NC}"
mkdir -p "$PACKER_DIR/build"
cp $JAR_PATH "$PACKER_DIR/build/application.jar"

# Validate Packer template
echo -e "${YELLOW}Validating Packer template...${NC}"
cd "$PACKER_DIR"
packer validate ami-template.json

if [ $? -ne 0 ]; then
    echo -e "${RED}Packer template validation failed${NC}"
    exit 1
fi

# Build the AMI
echo -e "${GREEN}Building AMI: ${AMI_NAME}${NC}"
packer build \
  -var "ami_name=$AMI_NAME" \
  -var "aws_region=${AWS_DEFAULT_REGION:-us-east-1}" \
  ami-template.json

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ AMI built successfully!${NC}"

    # Get the created AMI ID
    AMI_ID=$(aws ec2 describe-images \
      --owners self \
      --filters "Name=name,Values=${AMI_NAME}" \
      --query 'Images[0].ImageId' \
      --output text)

    echo -e "${GREEN}AMI ID: ${AMI_ID}${NC}"

    # Save AMI ID to file for future reference
    echo "$AMI_ID" > "$PROJECT_ROOT/latest-ami-id.txt"

    # Update SSM parameter (optional)
    if aws ssm describe-parameters --names "/java-app/latest-ami" &>/dev/null; then
        aws ssm put-parameter \
          --name "/java-app/latest-ami" \
          --value "$AMI_ID" \
          --type "String" \
          --overwrite
        echo -e "${GREEN}Updated SSM parameter /java-app/latest-ami${NC}"
    fi
else
    echo -e "${RED}✗ AMI build failed${NC}"
    exit 1
fi

# Clean up
echo -e "${YELLOW}Cleaning up...${NC}"
rm -rf "$PACKER_DIR/build"

echo -e "${GREEN}=== AMI Build Complete ===${NC}"