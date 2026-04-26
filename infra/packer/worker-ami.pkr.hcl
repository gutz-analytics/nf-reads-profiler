packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "db_source_bucket" {
  type    = string
  default = "cjb-gutz-s3-demo"
}

variable "ssm_parameter_name" {
  type    = string
  default = "/nf-reads-profiler/ami-id"
}

variable "vpc_id" {
  type    = string
  default = "vpc-06ad1e39bb8cd26df"
}

variable "subnet_id" {
  type    = string
  default = "subnet-09159c654acc505a3"
}

variable "instance_profile" {
  type    = string
  default = "nf-reads-profiler-ecs-instance-profile"
}

source "amazon-ebs" "worker" {
  ami_name      = "nf-reads-profiler-worker-{{timestamp}}"
  instance_type = "r8g.2xlarge"
  region        = var.region
  ssh_username  = "ec2-user"

  # 500 GiB snapshot can take 45+ min; default Packer timeout is too short
  aws_polling {
    delay_seconds = 30
    max_attempts  = 120
  }

  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id

  iam_instance_profile = var.instance_profile

  source_ami_filter {
    filters = {
      name                = "al2023-ami-ecs-hvm-*-kernel-*-arm64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
      state               = "available"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 500
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name    = "nf-reads-profiler-worker"
    Project = "nf-reads-profiler"
  }

  run_tags = {
    Name = "packer-nf-reads-profiler-worker"
  }
}

build {
  sources = ["source.amazon-ebs.worker"]

  # Install Miniconda + awscli
  provisioner "shell" {
    inline = [
      "ARCH=$(uname -m)",
      "if [ \"$ARCH\" = \"aarch64\" ]; then URL='https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-aarch64.sh'; else URL='https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh'; fi",
      "curl -fsSL \"$URL\" -o /tmp/miniconda.sh",
      "sudo bash /tmp/miniconda.sh -b -f -p /opt/conda-aws",
      "rm /tmp/miniconda.sh",
      "sudo /opt/conda-aws/bin/conda install -c conda-forge --override-channels -y awscli",
      "sudo /opt/conda-aws/bin/conda clean --all -y",
      "/opt/conda-aws/bin/aws --version",
    ]
  }

  # Sync databases from S3
  provisioner "shell" {
    environment_vars = [
      "DB_SOURCE_BUCKET=${var.db_source_bucket}",
    ]
    inline = [
      "sudo mkdir -p /mnt/dbs",
      "sudo /opt/conda-aws/bin/aws s3 sync s3://$DB_SOURCE_BUCKET /mnt/dbs/ --exclude '*' --include 'chocophlan_v4_alpha/*' --include 'full_mapping_v4_alpha/*' --include 'metaphlan_databases/*' --include 'uniref90_annotated_v4_alpha_ec_filtered/*'",
    ]
  }

  # Validate databases and awscli
  provisioner "shell" {
    inline = [
      "echo '=== Validating pre-baked content ==='",
      "for d in chocophlan_v4_alpha full_mapping_v4_alpha metaphlan_databases uniref90_annotated_v4_alpha_ec_filtered; do count=$(find /mnt/dbs/$d -type f | wc -l); echo \"$d: $count files\"; if [ \"$count\" -eq 0 ]; then echo \"FATAL: $d has no files\" >&2; exit 1; fi; done",
      "/opt/conda-aws/bin/aws --version",
      "echo '=== Validation passed ==='",
    ]
  }

  # Clean up for AMI snapshot
  provisioner "shell" {
    inline = [
      "sudo rm -rf /tmp/* /var/tmp/*",
      "sudo rm -f /var/log/nf-userdata.log",
      "sudo date -u '+%Y-%m-%dT%H:%M:%SZ' | sudo tee /mnt/dbs/.ami-build-timestamp",
    ]
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
