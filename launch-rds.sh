#!/bin/bash
set -eux
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )" # http://stackoverflow.com/questions/59895
. $DIR/setenv.sh
# http://docs.amazonwebservices.com/AmazonRDS/latest/CommandLineReference/CLIReference-cmd-CreateDBInstance.html
rds-create-db-instance            \
  --db-instance-identifier alpha  \
  --db-instance-class db.m1.small \
  --engine MySQL                  \
  --db-name archivesspace         \
  --master-user-password -        \
  --port 3306                     \
  --backup-retention-period 1     \
  --allocated-storage 10          \
  --master-username as            \
  --availability-zone $ZONE < ~/.ec2/.dbpass
