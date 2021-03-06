# Terraform configuration to run the ECS instances
# with wordpress
resource "aws_security_group" "elb_sg" {
        name = "elb_sg"
        description = "ELB Security Group"
        vpc_id = "${aws_vpc.ECSVPC.id}"

        ingress {
                from_port = 80
                to_port = 80
                protocol = "tcp"
                cidr_blocks = ["0.0.0.0/0"]
        }

        egress {
                from_port = 0
                to_port = 0
                protocol = "-1"
                cidr_blocks = ["0.0.0.0/0"]
        }
}

resource "aws_security_group" "ecs_sg" {
        name = "ecs_sg"
        description = "ECS Security Group"
        vpc_id = "${aws_vpc.ECSVPC.id}"

        ingress {
                from_port = 0
                to_port = 0
                protocol = "-1"
                security_groups = ["${aws_security_group.trust_sg.id}"]
        }

        egress {
                from_port = 0
                to_port = 0
                protocol = "-1"
                cidr_blocks = ["0.0.0.0/0"]
        }
}

resource "aws_elb" "elb" {
        name = "Wordpress-ELB"
        subnets = ["${aws_subnet.public.0.id}", "${aws_subnet.public.1.id}"]
        cross_zone_load_balancing = true
        idle_timeout = 400
        security_groups = ["${aws_security_group.trust_sg.id}", "${aws_security_group.elb_sg.id}"]

        listener {
                instance_port = 80
                instance_protocol = "http"
                lb_port = 80
                lb_protocol = "http"
        }

        health_check {
                healthy_threshold = 2
                unhealthy_threshold = 10
                timeout = 5
                target = "HTTP:80/readme.html"
                interval = 30
        }
}

resource "aws_key_pair" "ecs_key_pair" {
        key_name = "${var.ssh_key_name}"
        public_key = "${var.ssh_key}"
}

resource "aws_iam_role" "ecs_role" {
        name = "ecs_role"
        assume_role_policy = "${file("files/ecs-role.json")}"
}

resource "aws_iam_instance_profile" "ecs_profile" {
        name = "ecs_profile"
        path = "/"
        roles = ["${aws_iam_role.ecs_role.name}"]
}

resource "aws_launch_configuration" "ecs_lc" {
        name = "ecs_lc"
        image_id = "${lookup(var.ecs-ami, var.aws_region)}"
        instance_type = "${var.ecs-instance-type}"
        key_name = "${var.ssh_key_name}"
        iam_instance_profile = "${aws_iam_instance_profile.ecs_profile.name}"
        security_groups = ["${aws_security_group.trust_sg.id}", "${aws_security_group.ecs_sg.id}"]
        user_data = "#!/bin/bash\necho ECS_CLUSTER=${aws_ecs_cluster.wordpress-cluster.name} > /etc/ecs/ecs.config"
        depends_on = ["aws_key_pair.ecs_key_pair", "aws_ecs_cluster.wordpress-cluster"]
}

resource "aws_autoscaling_policy" "asg_policy" {
        name = "ASG-Policy-CPU-Usage"
        scaling_adjustment = 1
        adjustment_type = "ChangeInCapacity"
        cooldown = 300
        autoscaling_group_name = "${aws_autoscaling_group.ecs_asg.name}"
}

resource "aws_cloudwatch_metric_alarm" "cpu_alarm" {
        alarm_name = "CPU-Usage-Alarm"
        comparison_operator = "GreaterThanOrEqualToThreshold"
        evaluation_periods = 2
        metric_name = "CPUUtilization"
        namespace = "AWS/EC2"
        period = 120
        statistic = "Average"
        threshold = "70"
        dimensions {
                AutoScalingGroupName = "${aws_autoscaling_group.ecs_asg.name}"
        }
        alarm_description = "CPU Usage Alarm"
        alarm_actions = ["${aws_autoscaling_policy.asg_policy.arn}"]
}

resource "aws_autoscaling_group" "ecs_asg" {
        name = "ECS-AutoScalingGroup"
        vpc_zone_identifier = ["${aws_subnet.private.0.id}","${aws_subnet.private.1.id}"]
        max_size = 5
        min_size = 2
        health_check_grace_period = 300
        health_check_type = "EC2"
        launch_configuration = "${aws_launch_configuration.ecs_lc.name}"
        # load_balancers = ["${aws_elb.elb.id}"]
}

resource "template_file" "wordpress-json" {
        template = "${file("files/wordpress-task.json")}"

        vars {
                database_endpoint = "${aws_db_instance.wordpressdb.address}"
                database_name = "${var.database_name}"
                database_user = "${var.database_user}"
                database_password = "${var.database_password}"
        }
}

resource "aws_ecs_task_definition" "wordpress-task" {
        family = "terraform"
        container_definitions = "${template_file.wordpress-json.rendered}"
}

resource "aws_iam_role_policy" "ecs_service_role_policy" {
        name = "ecs_service_role_policy"
        policy = "${file("files/ecs-service-role-policy.json")}"
        role = "${aws_iam_role.ecs_role.id}"
}

resource "aws_iam_role_policy" "ecs_instance_role_policy" {
        name = "ecs_instance_role_policy"
        policy = "${file("files/ecs-instance-role-policy.json")}"
        role = "${aws_iam_role.ecs_role.id}"
}

resource "aws_ecs_service" "wordpress-service" {
        name = "wordpress-service"
        cluster = "${aws_ecs_cluster.wordpress-cluster.id}"
        task_definition = "${aws_ecs_task_definition.wordpress-task.arn}"
        desired_count = 1
        iam_role = "${aws_iam_role.ecs_role.arn}"
        depends_on = ["aws_iam_role_policy.ecs_service_role_policy"]

        load_balancer {
                elb_name = "${aws_elb.elb.id}"
                container_name = "wordpress-app"
                container_port = 80
        }
}

resource "aws_ecs_cluster" "wordpress-cluster" {
        name = "wordpress"
}
