terraform {
  backend "s3" {
    bucket         = "clsecurity-tf-01"
    key            = "terraform.tfstate"
    region         = "us-east-1"  # bijvoorbeeld voor AWS regio
    encrypt        = true
}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "3.66.0"
    }
  }
}

provider "aws" {
  region  = "us-east-1"
}
###################################################

#Variabelen
locals {
 sshkey  = "vockey"
}

###################################################
#Create a standard VPC
resource "aws_vpc" "saxit_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name  = "saxit_vpc"
  }
}

###################################################
#Create an internetgateway for the public subnets
resource "aws_internet_gateway" "saxit_gw" {
  vpc_id = aws_vpc.saxit_vpc.id

  tags = {
    Name  = "saxit_gw"
  }
}

# Create elastic ip for nat gateway
resource "aws_eip" "saxit_nat_gw_eip" {
  tags = {
    Name = "saxit_nat_gw_eip"
  }
}

# Create a NAT gateway for the presentation and application tiers
resource "aws_nat_gateway" "saxit_nat_gw" {
  connectivity_type = "public"
  subnet_id = aws_subnet.saxit_subnet_public_1.id
  allocation_id = aws_eip.saxit_nat_gw_eip.id
  tags = {
    Name = "saxit_nat_gw"
  }
}

###################################################
#Create peering with db VPC
resource "aws_vpc_peering_connection" "dbpeer" {
  vpc_id        = aws_vpc.saxit_vpc.id
  peer_vpc_id   = "vpc-0b5db9dc66cb74978"
  auto_accept   = true
}

###################################################
# Create routing table for public subnets
resource "aws_route_table" "public_route" {
  vpc_id = aws_vpc.saxit_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.saxit_gw.id 
  }
   tags = {
    Name = "public_route"
  }
}

# Create routing table for presentation and application tiers
resource "aws_route_table" "pres_app_route" {
  vpc_id = aws_vpc.saxit_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.saxit_nat_gw.id
  }
  route {
    cidr_block = "10.1.0.0/16"
    gateway_id = aws_vpc_peering_connection.dbpeer.id
  }
   tags = {
    Name = "pres_app_route"
  }
}

###################################################
# Create routing table for db VPC
resource "aws_route" "dbroute" {
  route_table_id         = "rtb-0724bcc3a3b6023fd"  # Existing route table ID db vpc
  destination_cidr_block = "10.0.0.0/16"
  gateway_id             = aws_vpc_peering_connection.dbpeer.id # peering id
}

###################################################
# Create security groups for presentationtier loadbalancer. Only allowing ingress from the internet and egress to the presentation tier EC2 instances
resource "aws_security_group" "presentationtier_sg_lb" {
  name = "presentationtier_sg_lb"
  description = "Allow traffic from internet to presentation tier loadbalancer"
  vpc_id = aws_vpc.saxit_vpc.id
}

resource "aws_security_group_rule" "presentationtier_sg_lb_ingress80" {
  security_group_id = aws_security_group.presentationtier_sg_lb.id
  description = "HTTP Ingress"
  type = "ingress"
  from_port = 80
  to_port = 80
  protocol = "tcp"
  cidr_blocks = ["0.0.0.0/0"] 
}

resource "aws_security_group_rule" "presentationtier_sg_lb_egress80" {
  security_group_id = aws_security_group.presentationtier_sg_lb.id
  type = "egress"
  description = "Forward to presentation EC2"
  from_port = 80
  to_port = 80
  protocol = "tcp"
  source_security_group_id = aws_security_group.presentationtier_sg_ec2.id
}

# Create security groups for presentationtier ec2. Only allowing ingress from bastion host and loadbalancer.
resource "aws_security_group" "presentationtier_sg_ec2" {
  name        = "presentationtier_sg_ec2"
  description = "Allow SSH and HTTP to web servers"
  vpc_id      = aws_vpc.saxit_vpc.id

}

resource "aws_security_group_rule" "presentationtier_sg_ec2_ingress22" {
  security_group_id = aws_security_group.presentationtier_sg_ec2.id
  type = "ingress"
  description = "SSH ingress"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  source_security_group_id = aws_security_group.bastion_sg.id
}

resource "aws_security_group_rule" "presentationtier_sg_ec2_ingress80" {
  security_group_id = aws_security_group.presentationtier_sg_ec2.id
  type = "ingress"
  description = "HTTP ingress"
  from_port   = 80
  to_port     = 80
  protocol    = "tcp"
  source_security_group_id = aws_security_group.presentationtier_sg_lb.id
}

resource "aws_security_group_rule" "presentationtier_sg_ec2_egressall" {
  security_group_id = aws_security_group.presentationtier_sg_ec2.id
  type = "egress"
  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

###################################################
# Create security group for applicationtier lb. Only allowing ingress from presentation tier EC2.
resource "aws_security_group" "applicationtier_sg_lb" {
  name = "applicationtier_sg_lb"
  description = "Allow HTTP from presentation tier to application tier EC2 instances"
  vpc_id = aws_vpc.saxit_vpc.id
}

# Allow ingress 8080 from application tier lb
resource "aws_security_group_rule" "applicationtier_sg_lb_ingress8080" {
  security_group_id = aws_security_group.applicationtier_sg_lb.id
  type = "ingress"
  description = "HTTP ingress"
  from_port = 8080
  to_port = 8080
  protocol = "TCP"
  cidr_blocks = ["0.0.0.0/0"]
}

# Allow egress 8080 to application tier EC2
resource "aws_security_group_rule" "applicationtier_sg_lb_egress8080" {
  security_group_id = aws_security_group.applicationtier_sg_lb.id
  description = "Allow HTTP to application tier EC2"
  type = "egress"
  from_port = 8080
  to_port = 8080
  protocol = "TCP"
  source_security_group_id = aws_security_group.applicationtier_sg_ec2.id
}

# Create security group for applicationtier ec2. Only allowing ingress from application tier loadbalancer and bastion host.
resource "aws_security_group" "applicationtier_sg_ec2" {
 name        = "applicationtier_sg_ec2"
 description = "Allow SSH and HTTP from presentation tier EC2 instances"
 vpc_id      = aws_vpc.saxit_vpc.id
}

# Allow SSH only from bastion host
resource "aws_security_group_rule" "applicationtier_sg_ec2_ingress22" {
  security_group_id = aws_security_group.applicationtier_sg_ec2.id
  type = "ingress"
  description = "SSH ingress"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  source_security_group_id = aws_security_group.bastion_sg.id
}

# Allow HTTP ingress on 8080 from application tier loadbalancer
resource "aws_security_group_rule" "applicationtier_sg_ec2_ingress8080" {
  security_group_id = aws_security_group.applicationtier_sg_ec2.id
  type = "ingress"
  description = "HTTP ingress"
  from_port   = 8080
  to_port     = 8080
  protocol    = "tcp"
  source_security_group_id = aws_security_group.applicationtier_sg_lb.id
}

# Allow internet access for now, because of userdata in EC2 instances. In the future of different deployment scnenario, you would restrict outbound access to only the application tier loadbalancer
resource "aws_security_group_rule" "applicationtier_sg_ec2_egressall" {
  security_group_id = aws_security_group.applicationtier_sg_ec2.id
  type = "egress"
  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

###################################################
# Create security group for bastion host
resource "aws_security_group" "bastion_sg" {
  name = "bastion_sg"
  description = "Security group for bastion host"
  vpc_id = aws_vpc.saxit_vpc.id
}

# Allow ingress from internet
resource "aws_security_group_rule" "bastion_sg_ingress22" {
  security_group_id = aws_security_group.bastion_sg.id
  type = "ingress"
  from_port = 22 
  to_port = 22
  protocol = "TCP"
  cidr_blocks = ["0.0.0.0/0"]
}

# Allow SSH egress to presentation tier EC2 instances
resource "aws_security_group_rule" "bastion_sg_egress22_presentation" {
  security_group_id = aws_security_group.bastion_sg.id
  type = "egress"
  from_port = 22
  to_port = 22
  protocol = "TCP"
  source_security_group_id = aws_security_group.presentationtier_sg_ec2.id
}

# Allow SSH egress to application tier EC2 instances
resource "aws_security_group_rule" "bastion_sg_egress22_application" {
  security_group_id = aws_security_group.bastion_sg.id
  type = "egress"
  from_port = 22
  to_port = 22
  protocol = "TCP"
  source_security_group_id = aws_security_group.applicationtier_sg_ec2.id
}

# Create bastion host EC2
resource "aws_instance" "bastion" {
  ami           = "ami-084568db4383264d4" # Amazon Ubuntu Linux 2 AMI
  instance_type = "t2.micro"              # Adjust instance type as needed
  subnet_id = aws_subnet.saxit_subnet_public_1.id
  associate_public_ip_address = true
  root_block_device {
    volume_type = "gp2"
    volume_size = 50 # Adjust volume size as needed
                    }
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]
  key_name = local.sshkey
  tags = {
     Name = "bastion"
  }
}

###################################################
# Create public subnets in both availability zones
resource "aws_subnet" "saxit_subnet_public_1" {
  vpc_id            = aws_vpc.saxit_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
  tags = {
    Name  = "saxit_subnet_public_1"
  }
}

resource "aws_subnet" "saxit_subnet_public_2" {
  vpc_id            = aws_vpc.saxit_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
  tags = {
    Name  = "saxit_subnet_public_2"
  }
}

###################################################
#Create different presentationtier subnets spread over 2 different availability zones 
resource "aws_subnet" "saxit_subnet_presentation_1" {
  vpc_id            = aws_vpc.saxit_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1a"
  tags = {
    Name  = "saxit_subnet_presentation_1"
  }
}

resource "aws_subnet" "saxit_subnet_presentation_2" {
  vpc_id            = aws_vpc.saxit_vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "us-east-1b"
  tags = {
    Name  = "saxit_subnet_presentation_2"
  }
}

###################################################
#Create different applicationtier subnets spread over 2 different availability zones 
resource "aws_subnet" "saxit_subnet_appl_1" {
  vpc_id            = aws_vpc.saxit_vpc.id
  cidr_block        = "10.0.5.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name  = "saxit_subnet_appl_1"
  }
}

resource "aws_subnet" "saxit_subnet_appl_2" {
  vpc_id            = aws_vpc.saxit_vpc.id
  cidr_block        = "10.0.6.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name  = "saxit_subnet_appl_2"
  }
}

###################################################
#Connect routing table to presentation subnets
resource "aws_route_table_association" "presentationtier1" {
  subnet_id      = aws_subnet.saxit_subnet_presentation_1.id
  route_table_id = aws_route_table.pres_app_route.id
}
resource "aws_route_table_association" "presentationtier2" {
  subnet_id      = aws_subnet.saxit_subnet_presentation_2.id
  route_table_id = aws_route_table.pres_app_route.id
}

###################################################
#Connect routing table to application subnets
resource "aws_route_table_association" "applicationtier1" {
  subnet_id      = aws_subnet.saxit_subnet_appl_1.id
  route_table_id = aws_route_table.pres_app_route.id
}
resource "aws_route_table_association" "applicationtier2" {
  subnet_id      = aws_subnet.saxit_subnet_appl_2.id
  route_table_id = aws_route_table.pres_app_route.id
}

# Connect routing table to public subnet
resource "aws_route_table_association" "public1" {
  subnet_id      = aws_subnet.saxit_subnet_public_1.id
  route_table_id = aws_route_table.public_route.id
}

resource "aws_route_table_association" "public2" {
  subnet_id      = aws_subnet.saxit_subnet_public_2.id
  route_table_id = aws_route_table.public_route.id
}

##################################################
# Use key for SSH
# Create SSH key first in GUI
##################################################
# Create an EC2 #1 instance as frontend
resource "aws_instance" "web01" {
  depends_on = [aws_lb.application-lb]
  ami           = "ami-084568db4383264d4" # Amazon Ubuntu Linux 2 AMI
  instance_type = "t2.micro"              # Adjust instance type as needed
  subnet_id = aws_subnet.saxit_subnet_presentation_1.id
  associate_public_ip_address = false
  root_block_device {
    volume_type = "gp2"
    volume_size = 50 # Adjust volume size as needed
                    }
  vpc_security_group_ids = [aws_security_group.presentationtier_sg_ec2.id]
 user_data = <<-EOF
  #!/bin/bash
  sudo apt update -y
  sudo apt upgrade -y
  sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y
  sudo apt-get install -y docker-ce
  sudo usermod -aG docker ubuntu
  sudo systemctl enable docker
  sudo systemctl start docker
  #Build the frontend image
  git clone https://github.com/intro-infra/cloudsec.git
  sudo echo "REACT_APP_API_BASE_URL=http://${aws_lb.application-lb.dns_name}:8080" > /cloudsec/frontend/.env
  cd /cloudsec/frontend
  sudo docker build -t frontend .
  sudo docker run --restart always -p 80:80 -d frontend
  EOF
  key_name = local.sshkey
 tags = {
     Name = "web01"
  }
}

##################################################
# Create an EC2 #2 instance as frontend
resource "aws_instance" "web02" {
  depends_on = [aws_lb.application-lb]
  ami           = "ami-084568db4383264d4" # Amazon Ubuntu Linux 2 AMI
  instance_type = "t2.micro"              # Adjust instance type as needed
  subnet_id = aws_subnet.saxit_subnet_presentation_2.id
  associate_public_ip_address = false
  root_block_device {
    volume_type = "gp2"
    volume_size = 50 # Adjust volume size as needed
                    }
  vpc_security_group_ids = [aws_security_group.presentationtier_sg_ec2.id]
 user_data = <<-EOF
 #!/bin/bash
  sudo apt update -y
  sudo apt upgrade -y
  sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y
  sudo apt-get install -y docker-ce
  sudo usermod -aG docker ubuntu
  sudo systemctl enable docker
  sudo systemctl start docker
  #Build the frontend image
  git clone https://github.com/intro-infra/cloudsec.git
  sudo echo "REACT_APP_API_BASE_URL=http://${aws_lb.application-lb.dns_name}:8080" > /cloudsec/frontend/.env
  cd /cloudsec/frontend
  sudo docker build -t frontend .
  sudo docker run --restart always -p 80:80 -d frontend
  EOF
  key_name = local.sshkey
 tags = {
     Name = "web02"
  }
}
##################################################
# Create an EC2 #1 instance as application
resource "aws_instance" "app01" {
  ami           = "ami-084568db4383264d4" # Amazon Ubuntu Linux 2 AMI
  instance_type = "t2.micro"              # Adjust instance type as needed
  subnet_id = aws_subnet.saxit_subnet_appl_1.id
  associate_public_ip_address = false
  root_block_device {
    volume_type = "gp2"
    volume_size = 50 # Adjust volume size as needed
                    }
vpc_security_group_ids = [aws_security_group.applicationtier_sg_ec2.id]		
 user_data = <<-EOF
  #!/bin/bash
  sudo apt update -y
  sudo apt upgrade -y
  sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y
  sudo apt-get install -y docker-ce
  sudo usermod -aG docker ubuntu
  sudo systemctl enable docker
  sudo systemctl start docker
  git clone https://github.com/cdemmer04/cloudsec.git
  # git clone https://github.com/intro-infra/cloudsec.git
  cd /cloudsec/backend
  sudo docker build -t backend .
  sudo docker run --restart always -e SPRING_DATASOURCE_URL=jdbc:mysql://terraform-20260902131906040600000001.cqvccucbipgf.us-east-1.rds.amazonaws.com/cloudsecdb -e SPRING_DATASOURCE_USERNAME=admin -e SPRING_DATASOURCE_PASSWORD=password123 -p 8080:8080 -d backend
  EOF
  key_name = local.sshkey
 tags = {
     Name = "app01"
  }
}
##################################################
# Create an EC2 #2 instance as application
resource "aws_instance" "app02" {
  ami           = "ami-084568db4383264d4" # Amazon Ubuntu Linux 2 AMI
  instance_type = "t2.micro"              # Adjust instance type as needed
  subnet_id = aws_subnet.saxit_subnet_appl_2.id
  associate_public_ip_address = false
  root_block_device {
    volume_type = "gp2"
    volume_size = 50 # Adjust volume size as needed
                    }
vpc_security_group_ids = [aws_security_group.applicationtier_sg_ec2.id]				
 user_data = <<-EOF
  #!/bin/bash
  sudo apt update -y
  sudo apt upgrade -y
  sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y
  sudo apt-get install -y docker-ce
  sudo usermod -aG docker ubuntu
  sudo systemctl enable docker
  sudo systemctl start docker
  git clone https://github.com/cdemmer04/cloudsec.git
  # git clone https://github.com/intro-infra/cloudsec.git
  cd /cloudsec/backend
  sudo docker build -t backend .
  sudo docker run --restart always -e SPRING_DATASOURCE_URL=jdbc:mysql://terraform-20260902131906040600000001.cqvccucbipgf.us-east-1.rds.amazonaws.com/cloudsecdb -e SPRING_DATASOURCE_USERNAME=admin -e SPRING_DATASOURCE_PASSWORD=password123 -p 8080:8080 -d backend
  EOF
  key_name = local.sshkey
 tags = {
     Name = "app02"
  }
}

###################################################
# Create loadbalancer presentation tier. Internet-facing
resource "aws_lb" "presentation-lb" {
  name               = "presentation-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.presentationtier_sg_lb.id]
  subnets            = [aws_subnet.saxit_subnet_public_1.id, aws_subnet.saxit_subnet_public_2.id]
  enable_deletion_protection = false
}

# Create targetgroup
resource "aws_lb_target_group" "presentation-lb-tg" {
  name        = "presentation-lb-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.saxit_vpc.id
  target_type = "ip"
  health_check {
    healthy_threshold   = "3"
    interval            = "30"
    protocol            = "HTTP"
    matcher             = "200"
    timeout             = "5"
    path                = "/"
    unhealthy_threshold = "2"
  }
}

# Create listners
resource "aws_alb_listener" "listener-http" {
  load_balancer_arn = aws_lb.presentation-lb.id
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.presentation-lb-tg.arn
  }
}

# Attach targetgroup to LB
resource "aws_lb_target_group_attachment" "presentation-attach1" {
    target_group_arn = aws_lb_target_group.presentation-lb-tg.arn
    target_id        = aws_instance.web01.private_ip
}

resource "aws_lb_target_group_attachment" "presentation-attach2" {
    target_group_arn = aws_lb_target_group.presentation-lb-tg.arn
    target_id        = aws_instance.web02.private_ip
}

###################################################
# Create loadbalancer appliction tier. Not internet-facing. Internal access only
resource "aws_lb" "application-lb" {
  name               = "application-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.applicationtier_sg_lb.id]
  subnets            = [aws_subnet.saxit_subnet_appl_1.id, aws_subnet.saxit_subnet_appl_2.id]
  enable_deletion_protection = false
 }
 
# Create targetgroup
resource "aws_lb_target_group" "application-lb-tg" {
  name        = "application-lb-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.saxit_vpc.id
  target_type = "ip"
  health_check {
    healthy_threshold   = "3"
    interval            = "30"
    protocol            = "HTTP"
    matcher             = "200-499"
    timeout             = "5"
    path                = "/"
    unhealthy_threshold = "2"
  }
}
# Create listners
resource "aws_alb_listener" "listener-http-appl" {
  load_balancer_arn = aws_lb.application-lb.id
  port              = 8080
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.application-lb-tg.arn
  }
}
# Attach targetgroup to LB
resource "aws_lb_target_group_attachment" "application-attach1" {
    target_group_arn = aws_lb_target_group.application-lb-tg.arn
    target_id        = aws_instance.app01.private_ip
}
resource "aws_lb_target_group_attachment" "application-attach2" {
    target_group_arn = aws_lb_target_group.application-lb-tg.arn
    target_id        = aws_instance.app02.private_ip
}


