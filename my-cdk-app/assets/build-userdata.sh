#!/bin/bash
set -euo pipefail

# Get CDK environment variables passed from stack
S3_BUCKET="$1"
REGION="$2"
LOG_GROUP_NAME="$3"
BUILD_LOG_STREAM="$4"
BUILD_SCRIPT="$5"

# Logging function for CloudWatch integration
log_to_cloudwatch() {
    local message="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message"
    aws logs put-log-events --log-group-name "$LOG_GROUP_NAME" --region "$REGION" --log-stream-name "$BUILD_LOG_STREAM" --log-events "timestamp=$(date +%s)000,message=\"$message\"" 2>/dev/null || true
}

# Install prerequisites
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y awscli curl wget snapd
log_to_cloudwatch "Prerequisites installed"

# Install SSM Agent for Session Manager (Ubuntu 22.04 compatible)
# Check if SSM Agent is already installed and running
if systemctl is-active --quiet amazon-ssm-agent || systemctl is-active --quiet snap.amazon-ssm-agent.amazon-ssm-agent.service; then
    log_to_cloudwatch "SSM Agent is already running"
else
    log_to_cloudwatch "Installing SSM Agent..."
    # For Ubuntu 22.04, prefer snap installation
    if command -v snap &> /dev/null; then
        log_to_cloudwatch "Installing SSM Agent via snap..."
        snap install amazon-ssm-agent --classic
        systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
        systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service
        sleep 5
        systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service --no-pager
    else
        # Fallback: Download and install manually
        log_to_cloudwatch "Installing SSM Agent via manual download..."
        wget -q https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
        dpkg -i amazon-ssm-agent.deb
        systemctl enable amazon-ssm-agent
        systemctl start amazon-ssm-agent
        sleep 5
        systemctl status amazon-ssm-agent --no-pager
    fi
fi
log_to_cloudwatch "SSM Agent setup completed"

chmod +x $BUILD_SCRIPT

# Set environment variables for the build script
export BUILD_DIR="/opt/aaos"

# Execute the build script
log_to_cloudwatch "Starting AAOS build process..."
$BUILD_SCRIPT
BUILD_RESULT=$?

if [ $BUILD_RESULT -eq 0 ]; then
    log_to_cloudwatch "Build script execution completed successfully"
    
    # Upload build artifacts to S3
    log_to_cloudwatch "Uploading build artifacts to S3..."
    
    # Upload target product files
    if [ -d "/opt/aaos/out/target/product/" ]; then
        log_to_cloudwatch "Uploading target product files to S3..."
        aws s3 cp --recursive /opt/aaos/out/target/product/ s3://$S3_BUCKET/aaos-target/ --region "$REGION" || log_to_cloudwatch "WARNING: Failed to upload target files"
    fi
    
    # Upload build logs
    BUILD_LOG=$(find /opt/aaos -name "build-*.log" | head -1)
    if [ -f "$BUILD_LOG" ]; then
        aws s3 cp "$BUILD_LOG" s3://$S3_BUCKET/build-logs/ --region "$REGION" || log_to_cloudwatch "WARNING: Failed to upload build log"
    fi
    
    # Upload cloud-init log
    if [ -f "/var/log/cloud-init-output.log" ]; then
        aws s3 cp /var/log/cloud-init-output.log s3://$S3_BUCKET/build-cloud-init-output.log --region "$REGION" || log_to_cloudwatch "WARNING: Failed to upload cloud-init log"
    fi
    
    log_to_cloudwatch "Build artifacts uploaded to S3 successfully"
    
    # Auto Scaling Group shutdown process
    log_to_cloudwatch "Initiating Auto Scaling Group shutdown..."
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    ASG_NAME=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region "$REGION" --query 'Reservations[0].Instances[0].Tags[?Key==`aws:autoscaling:groupName`].Value' --output text)
    
    if [ ! -z "$ASG_NAME" ] && [ "$ASG_NAME" != "None" ]; then
        log_to_cloudwatch "Found Auto Scaling Group: $ASG_NAME"
        if aws autoscaling update-auto-scaling-group --auto-scaling-group-name $ASG_NAME --desired-capacity 0 --region "$REGION"; then
            log_to_cloudwatch "✅ Successfully shut down Auto Scaling Group"
        else
            log_to_cloudwatch "❌ Failed to shut down Auto Scaling Group"
        fi
    fi
    
    log_to_cloudwatch "All tasks completed. Shutting down instance..."
    sleep 30
    shutdown -h now
else
    log_to_cloudwatch "❌ Build script failed with exit code: $BUILD_RESULT"
    exit $BUILD_RESULT
fi
