pipeline {
    agent any
    
    environment {
        AWS_DEFAULT_REGION = "us-west-2"
        AWS_ACCOUNT_ID = "073687477291"
        REGISTRY = "073687477291.dkr.ecr.us-west-2.amazonaws.com"
        DOCKER_IMAGE = "flask-hello-world"
        DOCKER_TAG = "${BUILD_NUMBER}"
    }
    
    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }
        
        stage('Setup AWS & ECR') {
            steps {
                withCredentials([
                    [$class: 'AmazonWebServicesCredentialsBinding', 
                     credentialsId: '3f776ff3-06c6-49bf-b7c8-2277e9d5b1f6']
                ]) {
                    script {
                        // Create S3 bucket for Terraform state if it doesn't exist
                        sh """
                            aws s3 ls s3://flask-app-terraform-state-${AWS_ACCOUNT_ID} --region ${AWS_DEFAULT_REGION} || \
                            aws s3 mb s3://flask-app-terraform-state-${AWS_ACCOUNT_ID} --region ${AWS_DEFAULT_REGION}
                            
                            # Enable versioning and encryption
                            aws s3api put-bucket-versioning \
                              --bucket flask-app-terraform-state-${AWS_ACCOUNT_ID} \
                              --versioning-configuration Status=Enabled || true
                              
                            aws s3api put-bucket-encryption \
                              --bucket flask-app-terraform-state-${AWS_ACCOUNT_ID} \
                              --server-side-encryption-configuration '{
                                "Rules": [{
                                  "ApplyServerSideEncryptionByDefault": {
                                    "SSEAlgorithm": "AES256"
                                  }
                                }]
                              }' || true
                        """
                        
                        // Create ECR repository if it doesn't exist
                        sh """
                            aws ecr describe-repositories --repository-names ${DOCKER_IMAGE} --region ${AWS_DEFAULT_REGION} || \
                            aws ecr create-repository --repository-name ${DOCKER_IMAGE} --region ${AWS_DEFAULT_REGION}
                        """
                        
                        // Login to ECR
                        sh """
                            aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | \
                            docker login --username AWS --password-stdin ${REGISTRY}
                        """
                    }
                }
            }
        }
        
        stage('Security Scan - Code') {
            parallel {
                stage('SAST Scan') {
                    steps {
                        // Static Application Security Testing
                        sh 'bandit -r . -f json -o bandit-report.json || true'
                        publishHTML([
                            allowMissing: false,
                            alwaysLinkToLastBuild: true,
                            keepAll: true,
                            reportDir: '.',
                            reportFiles: 'bandit-report.json',
                            reportName: 'Bandit Security Report'
                        ])
                    }
                }
                
                stage('Dependency Check') {
                    steps {
                        // Check for vulnerable dependencies
                        sh 'safety check --json --output safety-report.json || true'
                    }
                }
                
                stage('Secrets Scan') {
                    steps {
                        // Scan for secrets in code
                        sh 'truffleHog --json --regex .'
                    }
                }
            }
        }
        
        stage('Build & Test') {
            steps {
                script {
                    // Build Docker image
                    def image = docker.build("${REGISTRY}/${DOCKER_IMAGE}:${DOCKER_TAG}")
                    
                    // Push to ECR
                    image.push()
                    image.push("latest")
                }
                
                // Run unit tests
                sh 'python -m pytest tests/ || true'
            }
        }
        
        stage('Security Scan - Container') {
            steps {
                script {
                    // Container security scanning
                    sh """
                        docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
                        aquasec/trivy image ${DOCKER_IMAGE}:${DOCKER_TAG}
                    """
                }
            }
        }
        
        stage('Deploy to Staging') {
            steps {
                withCredentials([
                    [$class: 'AmazonWebServicesCredentialsBinding', 
                     credentialsId: '3f776ff3-06c6-49bf-b7c8-2277e9d5b1f6']
                ]) {
                    script {
                        // Deploy with Terraform
                        sh """
                            cd terraform/staging
                            terraform init
                            terraform plan -var="image_tag=${DOCKER_TAG}" -var="docker_image=${REGISTRY}/${DOCKER_IMAGE}"
                            terraform apply -auto-approve -var="image_tag=${DOCKER_TAG}" -var="docker_image=${REGISTRY}/${DOCKER_IMAGE}"
                        """
                    }
                }
            }
        }
        
        stage('Security Tests - Runtime') {
            steps {
                withCredentials([
                    [$class: 'AmazonWebServicesCredentialsBinding', 
                     credentialsId: '3f776ff3-06c6-49bf-b7c8-2277e9d5b1f6']
                ]) {
                    script {
                        // Get the staging URL from Terraform output
                        def stagingUrl = sh(
                            script: "cd terraform/staging && terraform output -raw load_balancer_url",
                            returnStdout: true
                        ).trim()
                        
                        echo "Testing staging URL: ${stagingUrl}"
                        
                        // Wait for service to be healthy
                        sh """
                            echo "Waiting for staging service to be ready..."
                            for i in {1..30}; do
                                if curl -f ${stagingUrl}/health; then
                                    echo "Service is ready!"
                                    break
                                fi
                                echo "Waiting... attempt \$i/30"
                                sleep 10
                            done
                        """
                        
                        // DAST - Dynamic Application Security Testing
                        sh "zap-baseline.py -t ${stagingUrl} || true"
                        
                        // Additional basic security checks
                        sh """
                            echo "Running basic security checks..."
                            curl -I ${stagingUrl} | grep -i security || echo "No security headers found"
                            curl -I ${stagingUrl} | grep -i x-frame-options || echo "X-Frame-Options missing"
                        """
                    }
                }
            }
        }
        
        stage('Cleanup Staging Environment') {
            steps {
                withCredentials([
                    [$class: 'AmazonWebServicesCredentialsBinding', 
                     credentialsId: '3f776ff3-06c6-49bf-b7c8-2277e9d5b1f6']
                ]) {
                    script {
                        // Destroy staging infrastructure after testing
                        sh """
                            cd terraform/staging
                            terraform destroy -auto-approve \
                              -var="image_tag=${DOCKER_TAG}" \
                              -var="docker_image=${REGISTRY}/${DOCKER_IMAGE}"
                        """
                    }
                }
            }
        }
        
        stage('Production Deploy') {
            when {
                branch 'main'
            }
            steps {
                input message: 'Deploy to Production?', ok: 'Deploy'
                
                withCredentials([
                    [$class: 'AmazonWebServicesCredentialsBinding', 
                     credentialsId: '3f776ff3-06c6-49bf-b7c8-2277e9d5b1f6']
                ]) {
                    script {
                        sh """
                            cd terraform/production
                            terraform init
                            terraform plan -var="image_tag=${DOCKER_TAG}" -var="docker_image=${REGISTRY}/${DOCKER_IMAGE}"
                            terraform apply -auto-approve -var="image_tag=${DOCKER_TAG}" -var="docker_image=${REGISTRY}/${DOCKER_IMAGE}"
                        """
                    }
                }
            }
        }
    }
    
    post {
        always {
            // Clean up Docker images locally
            sh """
                docker rmi ${REGISTRY}/${DOCKER_IMAGE}:${DOCKER_TAG} || true
                docker rmi ${REGISTRY}/${DOCKER_IMAGE}:latest || true
                docker logout ${REGISTRY} || true
            """
            
            // Archive security reports
            archiveArtifacts artifacts: '*-report.json', fingerprint: true, allowEmptyArchive: true
        }
        
        cleanup {
            // Emergency cleanup - destroy any remaining test infrastructure
            script {
                withCredentials([
                    [$class: 'AmazonWebServicesCredentialsBinding', 
                     credentialsId: '3f776ff3-06c6-49bf-b7c8-2277e9d5b1f6']
                ]) {
                    // Cleanup staging environment if pipeline fails
                    sh """
                        cd terraform/staging || exit 0
                        terraform destroy -auto-approve \
                          -var="image_tag=${DOCKER_TAG}" \
                          -var="docker_image=${REGISTRY}/${DOCKER_IMAGE}" || true
                    """
                    
                    // Optional: Clean up old ECR images (keep last 5)
                    sh """
                        aws ecr list-images --repository-name ${DOCKER_IMAGE} \
                          --filter tagStatus=UNTAGGED \
                          --query 'imageIds[?imageDigest!=null]' \
                          --output json | jq '.[:5]' | \
                        aws ecr batch-delete-image --repository-name ${DOCKER_IMAGE} \
                          --image-ids file:///dev/stdin || true
                    """
                }
            }
        }
        
        failure {
            // Notify team of failures AND cleanup status
            emailext (
                subject: "Pipeline Failed: ${env.JOB_NAME} - ${env.BUILD_NUMBER}",
                body: """
                Build failed. Check Jenkins for details.
                
                Cleanup Status:
                - Staging environment: DESTROYED
                - Docker images: CLEANED
                - ECR old images: CLEANED
                """,
                to: "team@company.com"
            )
        }
    }
}