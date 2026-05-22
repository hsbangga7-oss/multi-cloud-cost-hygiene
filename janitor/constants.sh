#!/usr/bin/env bash
# Pricing constants for cost estimation.
# All prices are USD, per month, as of 2026.
# Sources cited per line.

# EBS gp3 storage: $0.08/GB-month
# Source: https://aws.amazon.com/ebs/pricing/
EBS_COST_PER_GB_MONTH=0.08

# Elastic IP: $0.005/hour when not associated with a running instance
# = $0.005 * 730 hours/month = $3.65/month
# Source: https://aws.amazon.com/ec2/pricing/on-demand/#Elastic_IP_Addresses
EIP_COST_PER_HOUR=0.005
EIP_COST_PER_MONTH=3.65