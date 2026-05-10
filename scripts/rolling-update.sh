#!/bin/bash

set -e

# This script handles pull request deployments
PR_NUMBER=${CI_MERGE_REQUEST_IID:-${CI_COMMIT_BRANCH##pr-}}
DEPLOYMENT_NAME="pr-${PR_NUMBER}-deployment"

echo "=== Deploying PR #$PR_NUMBER ==="

# Get latest AMI
LATEST_AMI=$(aws ec2 describe-images \
  --owners self \
  --filters "Name=name,Values=java-app-*" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text)

# Create temporary instance for PR
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $LATEST_AMI \
  --instance-type t2.micro \
  --key-name $AWS_KEY_NAME \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$DEPLOYMENT_NAME},{Key=PRNumber,Value=$PR_NUMBER}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Started instance: $INSTANCE_ID"

# Wait for instance to be ready
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

INSTANCE_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "PR Deployment URL: http://$INSTANCE_IP:8080"

# Add comment to merge request with deployment URL
curl --request POST --header "PRIVATE-TOKEN: $GITLAB_API_TOKEN" \
  "https://gitlab.com/api/v4/projects/$CI_PROJECT_ID/merge_requests/$PR_NUMBER/notes" \
  --form "body=Deployed to: http://$INSTANCE_IP:8080"

# Store instance ID for cleanup
echo $INSTANCE_ID > /tmp/pr-instance-$PR_NUMBER.txt

# Wait for PR to be merged or closed
while true; do
  PR_STATE=$(curl --header "PRIVATE-TOKEN: $GITLAB_API_TOKEN" \
    "https://gitlab.com/api/v4/projects/$CI_PROJECT_ID/merge_requests/$PR_NUMBER" \
    | jq -r '.state')

  if [ "$PR_STATE" = "merged" ] || [ "$PR_STATE" = "closed" ]; then
    echo "PR $PR_NUMBER is $PR_STATE, cleaning up..."
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID
    break
  fi

  sleep 60
done