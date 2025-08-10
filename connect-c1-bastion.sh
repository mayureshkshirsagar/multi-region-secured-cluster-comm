#!/usr/bin/env bash

# Start an SSM session to the bastion instance
aws ssm start-session --region $(terraform output -raw region_a) --target $(terraform output -raw c1_bastion_instance_id)
