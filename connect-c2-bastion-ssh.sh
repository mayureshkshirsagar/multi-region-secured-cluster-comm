#!/usr/bin/env bash
ssh -i bastion.pem ec2-user@$(terraform output -raw c2_bastion_public_ip)