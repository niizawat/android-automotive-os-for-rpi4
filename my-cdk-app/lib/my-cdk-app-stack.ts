import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as autoscaling from "aws-cdk-lib/aws-autoscaling";
import * as iam from "aws-cdk-lib/aws-iam";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as s3deploy from "aws-cdk-lib/aws-s3-deployment";
import * as s3assets from "aws-cdk-lib/aws-s3-assets";
import * as logs from "aws-cdk-lib/aws-logs";
import * as path from "path";
import { Construct } from "constructs";

export class BuildAaosRpi4ImageStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // フラグでTarget Instanceのデプロイを制御
    const deployTargetInstance =
      this.node.tryGetContext("deployTargetInstance") ?? false;

    // Region mappings for AMIs
    const regionMap = new cdk.CfnMapping(this, "RegionMap", {
      mapping: {
        "ap-northeast-1": {
          buildami: "ami-0d52744d6551d851e",
          targetami: "ami-0b4630ef8a2b167d9",
        },
        "ap-southeast-1": {
          buildami: "ami-0df7a207adb9748c7",
          targetami: "ami-0e3d9e3a3bac2a3c9",
        },
        "eu-west-2": {
          buildami: "ami-0eb260c4d5475b901",
          targetami: "ami-0b3a47cf79203cd3f",
        },
        "eu-west-1": {
          buildami: "ami-01dd271720c1ba44f",
          targetami: "ami-09e8e9f9b1b4067d9",
        },
        "eu-central-1": {
          buildami: "ami-04e601abe3e1a910f",
          targetami: "ami-058b550e3dc714613",
        },
        "us-east-1": {
          buildami: "ami-053b0d53c279acc90",
          targetami: "ami-06be7c79234a3be48",
        },
        "us-east-2": {
          buildami: "ami-024e6efaf93d85776",
          targetami: "ami-0de2b061fc594daad",
        },
        "us-west-2": {
          buildami: "ami-03f65b8614a860c29",
          targetami: "ami-009c2d20a323f18cb",
        },
      },
    });

    // IAM Role for EC2 instances
    const aaosRole = new iam.Role(this, "AAOSRole", {
      roleName: `aaos-role-${this.region}-${this.stackName}`,
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      inlinePolicies: {
        AAOSPolicy: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: [
                "s3:PutObject",
                "s3:GetObject",
                "s3:ListBucket",
                "s3:ListObject",
                "logs:PutLogEvents",
                "ec2:TerminateInstances",
                "autoscaling:UpdateAutoScalingGroup",
                "autoscaling:DescribeAutoScalingGroups",
                "ec2:DescribeInstances",
                // Session Manager用の権限
                "ssm:UpdateInstanceInformation",
                "ssm:SendCommand",
                "ssm:ListCommands",
                "ssm:ListCommandInvocations",
                "ssm:DescribeInstanceInformation",
                "ssm:GetConnectionStatus",
                "ssm:DescribeInstanceProperties",
                "ssm:StartSession",
                "ssmmessages:CreateControlChannel",
                "ssmmessages:CreateDataChannel",
                "ssmmessages:OpenControlChannel",
                "ssmmessages:OpenDataChannel",
                "ec2messages:AcknowledgeMessage",
                "ec2messages:DeleteMessage",
                "ec2messages:FailMessage",
                "ec2messages:GetEndpoint",
                "ec2messages:GetMessages",
                "ec2messages:SendReply",
              ],
              resources: ["*"],
            }),
          ],
        }),
      },
    });

    // S3 Bucket for AAOS output
    const timestamp = Date.now();
    const aaosBucket = new s3.Bucket(this, "AAOSBucket", {
      bucketName: `aaos-output-${this.region}-${
        this.account
        }-${this.stackName.toLowerCase()}-${timestamp}`,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // CloudWatch Log Group and Streams
    const aaosLogGroup = new logs.LogGroup(this, "AAOSLogGroup", {
      logGroupName: `AAOSLogs-${this.region}-${this.stackName}-${timestamp}`,
      retention: logs.RetentionDays.ONE_DAY,
    });

    const aaosBuildStream = new logs.LogStream(this, "AAOSBuildStream", {
      logGroup: aaosLogGroup,
      logStreamName: `AAOSBuild-${this.region}-${this.stackName}`,
    });

    const aaosTargetStream = new logs.LogStream(this, "AAOSTargetStream", {
      logGroup: aaosLogGroup,
      logStreamName: `AAOSTarget-${this.region}-${this.stackName}`,
    });

    // EC2 Key Pair
    const aaosKeyPair = new ec2.KeyPair(this, "AAOSKeyPair", {
      keyPairName: `AAOSInstanceKey-${this.region}-${this.stackName}`,
    });

    // Default VPC
    const defaultVpc = ec2.Vpc.fromLookup(this, "DefaultVpc", {
      isDefault: true,
    });

    // UserData Asset - Upload local script to S3 and execute
    const userDataAsset = new s3assets.Asset(this, "UserDataAsset", {
      path: path.join(__dirname, "..", "assets", "build-userdata.sh"),
    });

    const buildScriptAsset = new s3assets.Asset(this, "BuildScriptAsset", {
      path: path.join(__dirname, "..", "assets", "build-aaos15-rpi4.sh"),
    });

    // Build Instance Launch Template - Use Asset-deployed script
    const buildUserData = ec2.UserData.forLinux();
    
    // Grant read access to the UserData asset
    userDataAsset.grantRead(aaosRole);
    
    buildUserData.addCommands(
      "apt update && apt install -y awscli && echo 'awscli installed' > /var/tmp/setup"
    );

    const buildScriptPath = buildUserData.addS3DownloadCommand({
      bucket: buildScriptAsset.bucket,
      bucketKey: buildScriptAsset.s3ObjectKey,
    });

    // Download the UserData script from S3
    const localPath = buildUserData.addS3DownloadCommand({
      bucket: userDataAsset.bucket,
      bucketKey: userDataAsset.s3ObjectKey,
    });
    
    // Execute the downloaded script with parameters
    buildUserData.addExecuteFileCommand({
      filePath: localPath,
      arguments: `${aaosBucket.bucketName} ${this.region} ${aaosLogGroup.logGroupName} ${aaosBuildStream.logStreamName} ${buildScriptPath}`,
    });

    // Target Instance User Data (フラグで制御)
    let targetInstance: ec2.Instance | undefined;

    // Build Instance用LaunchTemplate（スポットインスタンス対応）
    const buildLaunchTemplate = new ec2.LaunchTemplate(this, "BuildLaunchTemplate", {
      launchTemplateName: `AAOS-Build-LT-${this.region}-${this.stackName}`,
      machineImage: ec2.MachineImage.genericLinux({
        [this.region]: regionMap.findInMap(this.region, "buildami"),
      }),
      keyPair: aaosKeyPair,
      // securityGroup: aaosSecurityGroup,
      role: aaosRole,
      userData: buildUserData,
      requireImdsv2: true,
      blockDevices: [
        {
          deviceName: "/dev/sda1",
          volume: ec2.BlockDeviceVolume.ebs(350, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            iops: 3000,
            deleteOnTermination: true,
          }),
        },
      ],
    });

    // Build Instance用AutoScalingGroup（スポットインスタンス）
    const buildAutoScalingGroup = new autoscaling.AutoScalingGroup(this, "BuildAutoScalingGroup", {
      vpc: defaultVpc,
      minCapacity: 0, // ビルド完了後の自動再起動を防ぐため0に設定
      maxCapacity: 1,
      desiredCapacity: 1,
      autoScalingGroupName: `AAOS-Build-ASG-${this.region}-${this.stackName}`,
      mixedInstancesPolicy: {
        instancesDistribution: {
          spotAllocationStrategy: autoscaling.SpotAllocationStrategy.LOWEST_PRICE,
          spotInstancePools: 3,
          spotMaxPrice: "0.50",
          onDemandPercentageAboveBaseCapacity: 0, // 100%スポットインスタンス
        },
        launchTemplate: buildLaunchTemplate,
        launchTemplateOverrides: [
          { instanceType: ec2.InstanceType.of(ec2.InstanceClass.C6A, ec2.InstanceSize.XLARGE8) },
          { instanceType: ec2.InstanceType.of(ec2.InstanceClass.C5, ec2.InstanceSize.XLARGE9) },
          { instanceType: ec2.InstanceType.of(ec2.InstanceClass.C5N, ec2.InstanceSize.XLARGE9) },
          { instanceType: ec2.InstanceType.of(ec2.InstanceClass.C6I, ec2.InstanceSize.XLARGE8) },
        ],
      },
    });

    if (deployTargetInstance) {
      // Security Group
      const aaosSecurityGroup = new ec2.SecurityGroup(this, "AAOSSG", {
        vpc: defaultVpc,
        securityGroupName: `aaos-secgroup-${this.region}-${this.stackName}`,
        description: "AAOS Instance Security Group - For Instance Access",
      });

      aaosSecurityGroup.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(6520));
      aaosSecurityGroup.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(8443));
      aaosSecurityGroup.addIngressRule(
        ec2.Peer.anyIpv4(),
        ec2.Port.tcpRange(15550, 15599)
      );
      aaosSecurityGroup.addIngressRule(
        ec2.Peer.anyIpv4(),
        ec2.Port.udpRange(15550, 15599)
      );

      // Target Instance User Data
      const targetUserData = ec2.UserData.forLinux();
      targetUserData.addCommands(
        "#!/bin/bash",
        "timestamp=$(date +%s)",
        "timestamp=$((timestamp*1000))",
        "sudo su",
        "export HOME=/root",
        "export XDG_CACHE_HOME=/root/.cache",
        "export GOCACHE=/root/.cache/go",
        "mkdir -p /root/.cache/go",
        "export DEBIAN_FRONTEND=noninteractive",
        "sed -i \"/#\\$nrconf{restart} = 'i';/s/.*/\\$nrconf{restart} = 'a';/\" /etc/needrestart/needrestart.conf",
        "apt-get update -y",
        "apt-get install -y libprotobuf-dev protobuf-compiler nfs-common binutils u-boot-tools",
        "apt-get install -y git devscripts config-package-dev debhelper-compat golang libssl-dev",
        "apt-get install -y clang meson libfmt-dev libgflags-dev libjsoncpp-dev libcurl4-openssl-dev libgoogle-glog-dev libgtest-dev libxml2-dev uuid-dev libprotobuf-c-dev libz3-dev",
        "apt-get install dpkg-dev -y",
        "apt-get -y install python3-pip",
        "apt-get -y install awscli",
        "apt-get -y install unzip",
        "mkdir -p /opt/aws/",
        "pip3 install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-py3-latest.tar.gz",
        "ln -s /usr/local/init/ubuntu/cfn-hup /etc/init.d/cfn-hup",
        `aws logs put-log-events --log-group-name ${aaosLogGroup.logGroupName} --region ${this.region} --log-stream-name ${aaosTargetStream.logStreamName} --log-events timestamp="$timestamp",message="Step 1 of 6 - Core Libraries Installed and services running - awaiting sync with build instance"`,
        "while true; do",
        `  aws s3 cp s3://${aaosBucket.bucketName}/u-boot.bin .`,
        '  if [ ! -f "u-boot.bin" ]; then',
        '    echo "File not ready yet!"',
        "    sleep 60",
        "  else",
        '    echo "Found"',
        "    break",
        "  fi",
        "done",
        "timestamp=$(date +%s)",
        "timestamp=$((timestamp*1000))",
        `aws logs put-log-events --log-group-name ${aaosLogGroup.logGroupName} --region ${this.region} --log-stream-name ${aaosTargetStream.logStreamName} --log-events timestamp="$timestamp",message="Step 2 of 6 - AAOS Build images available - downloading and installing cuttlefish"`,
        "sleep 5",
        "cd ~",
        "cd /home/ubuntu",
        "git clone https://github.com/google/android-cuttlefish --branch v0.9.27",
        "cd android-cuttlefish",
        "for dir in base frontend; do",
        "  pushd $dir",
        "  mk-build-deps -i",
        "  dpkg-buildpackage -uc -us",
        "  popd",
        "done",
        "apt install -y ./cuttlefish-base_*.deb",
        "apt install -y ./cuttlefish-user_*.deb",
        "usermod -aG kvm,cvdnetwork,render ubuntu",
        "timestamp=$(date +%s)",
        "timestamp=$((timestamp*1000))",
        `aws logs put-log-events --log-group-name ${aaosLogGroup.logGroupName} --region ${this.region} --log-stream-name ${aaosTargetStream.logStreamName} --log-events timestamp="$timestamp",message="Step 3 of 6 - Cuttlefish installed - unpacking and configuring AAOS Build images"`,
        "cd /home/ubuntu",
        "mkdir /home/ubuntu/stage",
        "cd /home/ubuntu/stage",
        `aws s3 cp s3://${aaosBucket.bucketName}/cvd-host_package.tar.gz .`,
        `aws s3 cp s3://${aaosBucket.bucketName}/images.zip .`,
        "tar xvf ./cvd-host_package.tar.gz",
        "unzip ./images.zip",
        `aws s3 cp s3://${aaosBucket.bucketName}/u-boot.bin ./bootloader`,
        "cp /usr/bin/mkenvimage ./bin/mkenvimage",
        "chown -R ubuntu:ubuntu /home/ubuntu/stage",
        "timestamp=$(date +%s)",
        "timestamp=$((timestamp*1000))",
        `aws logs put-log-events --log-group-name ${aaosLogGroup.logGroupName} --region ${this.region} --log-stream-name ${aaosTargetStream.logStreamName} --log-events timestamp="$timestamp",message="Step 4 of 6 - Creating and Starting Cuttlefish Service"`,
        "cat <<EOF >>/etc/systemd/system/cvd.service",
        "[Unit]",
        "Description=Cuttlefish Virtual Device",
        "After=multi-user.target",
        "[Service]",
        "Environment='HOME=/home/ubuntu/stage'",
        "Type=simple",
        "User=ubuntu",
        "Group=ubuntu",
        "ExecStart=/bin/sh -c 'yes Y | /home/ubuntu/stage/bin/launch_cvd'",
        "ExecStop=/home/ubuntu/stage/bin/stop_cvd",
        "[Install]",
        "WantedBy=multi-user.target",
        "EOF",
        "chmod 644 /etc/systemd/system/cvd.service",
        "systemctl daemon-reload",
        "systemctl enable cvd.service",
        "systemctl restart cvd.service",
        "systemctl status cvd.service",
        "timestamp=$(date +%s)",
        "timestamp=$((timestamp*1000))",
        `aws logs put-log-events --log-group-name ${aaosLogGroup.logGroupName} --region ${this.region} --log-stream-name ${aaosTargetStream.logStreamName} --log-events timestamp="$timestamp",message="Step 5 of 6 - Cuttlefish Service is running"`,
        "timestamp=$(date +%s)",
        "timestamp=$((timestamp*1000))",
        'WEBIP="$(curl http://169.254.169.254/latest/meta-data/public-ipv4)"',
        'WEBFULL="AAOS Interface Address : https://$WEBIP:8443"',
        `aws logs put-log-events --log-group-name ${aaosLogGroup.logGroupName} --region ${this.region} --log-stream-name ${aaosTargetStream.logStreamName} --log-events timestamp="$timestamp",message="$WEBFULL"`,
        "timestamp=$(date +%s)",
        "timestamp=$((timestamp*1000))",
        `aws logs put-log-events --log-group-name ${aaosLogGroup.logGroupName} --region ${this.region} --log-stream-name ${aaosTargetStream.logStreamName} --log-events timestamp="$timestamp",message="Step 6 of 6 - AAOS is running and Interface created - Rebooting the instance once reboot is complete AAOS will be available at provided address"`,
        `aws s3 cp /var/log/cloud-init-output.log s3://${aaosBucket.bucketName}/target-cloud-init-output.log`,
        "sleep 5",
        "reboot"
      );

      // Target Instance
      targetInstance = new ec2.Instance(this, "TargetInstance", {
        instanceType: ec2.InstanceType.of(
          ec2.InstanceClass.M6G,
          ec2.InstanceSize.METAL
        ),
        machineImage: ec2.MachineImage.genericLinux({
          [this.region]: regionMap.findInMap(this.region, "targetami"),
        }),
        vpc: defaultVpc,
        keyPair: aaosKeyPair,
        securityGroup: aaosSecurityGroup,
        role: aaosRole,
        userData: targetUserData,
        blockDevices: [
          {
            deviceName: "/dev/sda1",
            volume: ec2.BlockDeviceVolume.ebs(100, {
              volumeType: ec2.EbsDeviceVolumeType.GP3,
              iops: 3000,
              deleteOnTermination: true,
            }),
          },
        ],
      });
    }

    // Add tags
    cdk.Tags.of(buildAutoScalingGroup).add("Name", `AAOS-${this.stackName}-Build`);
    if (targetInstance) {
      cdk.Tags.of(targetInstance).add("Name", `AAOS-${this.stackName}-Target`);
    }

    // Stack Outputs
    new cdk.CfnOutput(this, "AAOSS3BucketName", {
      description: "The S3 Bucket created by the AAOS CloudFormation Stack",
      value: aaosBucket.bucketName,
    });

    if (targetInstance) {
      new cdk.CfnOutput(this, "TargetInstanceName", {
        description:
          "The Graviton Powered Instance created to host the Android Automotive OS.",
        value: targetInstance.instanceId,
      });
    }

    new cdk.CfnOutput(this, "BuildAutoScalingGroupName", {
      description:
        "The Auto Scaling Group (Spot Instance) created to build the Android Automotive operating system from source",
      value: buildAutoScalingGroup.autoScalingGroupName,
    });

    new cdk.CfnOutput(this, "AAOSBuildLogStream", {
      description:
        "The build instance log stream, where you can view the summerised output from the build process",
      value: aaosBuildStream.logStreamName,
    });

    new cdk.CfnOutput(this, "AAOSTargetLogStream", {
      description:
        "The target instance log stream, where you can view the output from the target instance configuration",
      value: aaosTargetStream.logStreamName,
    });

    if (targetInstance) {
      new cdk.CfnOutput(this, "AAOSWebInterface", {
        description:
          "The web address from which you can access the Android Automotive OS once the build process completes (Around 2 hours from Stack Deployment)",
        value: `https://${targetInstance.instancePublicIp}:8443`,
      });
    }
  }
}
