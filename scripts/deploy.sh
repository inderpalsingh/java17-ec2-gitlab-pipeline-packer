#!/bin/bash

set -e

# Variables
INSTANCE_NAME="java-app-instance"
KEY_NAME="${AWS_KEY_NAME}"
SECURITY_GROUP_NAME="java-app-sg"
LAUNCH_TEMPLATE_NAME="java-app-lt"
INSTANCE_TYPE="t2.micro"

echo "=== Starting Deployment ==="

# Get latest AMI ID
LATEST_AMI=$(aws ec2 describe-images \
  --owners self \
  --filters "Name=name,Values=java-app-*" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text)

echo "Latest AMI ID: $LATEST_AMI"

# Create or update launch template
aws ec2 create-launch-template-version \
  --launch-template-name $LAUNCH_TEMPLATE_NAME \
  --version-description "Version $(date +%Y%m%d-%H%M%S)" \
  --source-version '$Latest' \
  --launch-template-data "{\"ImageId\":\"$LATEST_AMI\",\"InstanceType\":\"$INSTANCE_TYPE\",\"KeyName\":\"$KEY_NAME\"}" || \
  aws ec2 create-launch-template \
    --launch-template-name $LAUNCH_TEMPLATE_NAME \
    --launch-template-data "{\"ImageId\":\"$LATEST_AMI\",\"InstanceType\":\"$INSTANCE_TYPE\",\"KeyName\":\"$KEY_NAME\"}"

# Get existing instance ID (for blue-green deployment)
OLD_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

echo "Old Instance ID: $OLD_INSTANCE_ID"

# Launch new instance
NEW_INSTANCE_ID=$(aws ec2 run-instances \
  --launch-template "LaunchTemplateName=$LAUNCH_TEMPLATE_NAME,Version=\$Latest" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=DeploymentTime,Value=$(date +%s)}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "New Instance ID: $NEW_INSTANCE_ID"

# Wait for instance to be running
aws ec2 wait instance-running --instance-ids $NEW_INSTANCE_ID
echo "New instance is running"

# Get instance IP
NEW_INSTANCE_IP=$(aws ec2 describe-instances \
  --instance-ids $NEW_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "New Instance IP: $NEW_INSTANCE_IP"

# Wait for application to be ready
sleep 30

# Test new instance
if curl -f http://$NEW_INSTANCE_IP:8080/health; then
  echo "New instance is healthy"

  # Terminate old instance if exists
  if [ "$OLD_INSTANCE_ID" != "None" ]; then
    echo "Terminating old instance: $OLD_INSTANCE_ID"
    aws ec2 terminate-instances --instance-ids $OLD_INSTANCE_ID
  fi

  # Update GitLab variable for verification
  curl --request PUT --header "PRIVATE-TOKEN: $GITLAB_API_TOKEN" \
    "https://gitlab.com/api/v4/projects/$CI_PROJECT_ID/variables/EC2_INSTANCE_IP" \
    --form "value=$NEW_INSTANCE_IP"

  echo "Deployment completed successfully!"
else
  echo "New instance health check failed, rolling back..."
  aws ec2 terminate-instances --instance-ids $NEW_INSTANCE_ID
  exit 1
fi