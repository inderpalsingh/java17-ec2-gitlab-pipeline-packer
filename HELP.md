# Complete Setup Guide with CI/CD Pipeline

---

## Usage Examples

### Build a new AMI:
```
aws configure
```

### OR

```
export AWS_ACCESS_KEY_ID=your_key
export AWS_SECRET_ACCESS_KEY=your_secret
export AWS_DEFAULT_REGION=us-east-1

./scripts/build-ami.sh
```

### Create a new EC2 instance:

```
# Using latest AMI
./scripts/create-instance.sh -k your-key-name

# With specific AMI
./scripts/create-instance.sh -k your-key-name -a ami-12345678

# With custom name and type
./scripts/create-instance.sh -n my-java-app -t t3.small -k your-key-name
```


### Create instance with all options:

```
./scripts/create-instance.sh \
    --name production-app \
    --instance-type t3.medium \
    --key-name my-key-pair \
    --security-group sg-12345678 \
    --region us-west-2
```

### Build the Java application and AMI:

```
./gradlew build
./scripts/build-ami.sh
```

### Create an EC2 instance:

```
./scripts/create-instance.sh -k your-key-name
```
### Test the deployment:
```
##  Get the instance IP from the output
curl http://<instance-ip>:8080/
curl http://<instance-ip>:8080/health
```