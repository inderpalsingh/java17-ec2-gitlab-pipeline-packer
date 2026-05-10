pipeline {
    agent any

    environment {
        AWS_DEFAULT_REGION = 'us-east-1'
        ECR_REPOSITORY_BACKEND = 'todo-backend'
        ECR_REPOSITORY_FRONTEND = 'todo-frontend'
        ECS_CLUSTER = 'todo-cluster'
        ECS_SERVICE = 'todo-service'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build Backend') {
            steps {
                dir('backend') {
                    sh 'mvn clean package -DskipTests'
                }
            }
        }

        stage('Build Frontend') {
            steps {
                dir('frontend') {
                    sh 'npm ci'
                    sh 'npm run build'
                }
            }
        }

        stage('Docker Build & Push') {
            steps {
                script {
                    // Login to ECR
                    sh "aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | docker login --username AWS --password-stdin ${aws.accountId}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"

                    // Build and push backend
                    dir('backend') {
                        sh "docker build -t ${ECR_REPOSITORY_BACKEND}:latest ."
                        sh "docker tag ${ECR_REPOSITORY_BACKEND}:latest ${aws.accountId}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/${ECR_REPOSITORY_BACKEND}:latest"
                        sh "docker push ${aws.accountId}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/${ECR_REPOSITORY_BACKEND}:latest"
                    }

                    // Build and push frontend
                    dir('frontend') {
                        sh "docker build -t ${ECR_REPOSITORY_FRONTEND}:latest ."
                        sh "docker tag ${ECR_REPOSITORY_FRONTEND}:latest ${aws.accountId}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/${ECR_REPOSITORY_FRONTEND}:latest"
                        sh "docker push ${aws.accountId}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/${ECR_REPOSITORY_FRONTEND}:latest"
                    }
                }
            }
        }

        stage('Deploy to ECS') {
            steps {
                script {
                    sh "aws ecs update-service --cluster ${ECS_CLUSTER} --service ${ECS_SERVICE} --force-new-deployment"
                }
            }
        }

        stage('Integration Tests') {
            steps {
                sh 'echo "Running integration tests..."'
                // Add integration tests here
            }
        }
    }

    post {
        always {
            cleanWs()
        }
        success {
            echo 'Pipeline succeeded! Application deployed successfully.'
        }
        failure {
            echo 'Pipeline failed! Check the logs for details.'
        }
    }
}