#!/bin/bash

echo "=== Java Application Instances ==="
aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=java-app-*" \
    --query 'Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' \
    --output table