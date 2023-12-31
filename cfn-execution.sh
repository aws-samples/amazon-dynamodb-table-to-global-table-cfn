#!/bin/bash

## USAGE:
## You can either change the variables below OR pass in a step number
## It will only execute the step you pass
## Example ./cfn-execution 1

### OPTIONS
TABLE_NAME='CfnTestPrices'
STACK_NAME='cfn-demo-dynamodb'
PRIMARY_REGION='us-east-2'
REPLICA_REGION='us-east-1'
DEFAULT_STEP=1


##INFO
SCRIPT_DIR=$( echo `pwd` | head -n 1)
EXE_STEP=$DEFAULT_STEP
echo "SCRIPT DIR: $SCRIPT_DIR"
echo " "
echo "########################################"
echo " " 

##FUNCTIONS

### WAITS FOR EXECUTION OF CFN 
check_execution_status() {
  echo " "
  STACK_NAME=$1
  REGION=$2
  STEP=$3
  if [ $STEP == 4 ];then
    EXPECTED_RESULT="IMPORT_COMPLETE"
  else
    EXPECTED_RESULT="UPDATE_COMPLETE"
  fi
  echo -n "Wating for execution to complete."
  CFN_STATUS_CMD=$(aws cloudformation describe-stack-events --stack-name $STACK_NAME --region $REGION --max-items 1 --query 'StackEvents[0].ResourceStatus' --output text | head -n 1)
  while [ "$CFN_STATUS_CMD" != "$EXPECTED_RESULT" ]; do
    echo -n '.'
    sleep 2
    CFN_STATUS_CMD=$(aws cloudformation describe-stack-events --stack-name $STACK_NAME --region $REGION --max-items 1 --query 'StackEvents[0].ResourceStatus' --output text | head -n 1)
  done
  echo " "
}

### GETS COUNT OF ITEMS in DYNAMODB TABLE
get_item_count() {
  TABLE_NAME=$1
  REGION=$2

  aws dynamodb describe-table --table-name $TABLE_NAME --region $REGION
  aws application-autoscaling describe-scalable-targets --service-namespace dynamodb --resource-id "table/$TABLE_NAME" --region $REGION
  aws application-autoscaling describe-scaling-policies --service-namespace dynamodb --resource-id "table/$TABLE_NAME" --region $REGION

  ITEM_COUNT=$(aws dynamodb scan --table-name $TABLE_NAME --select "COUNT" --region $REGION --query "Count" --output text)
  echo "Item Count in $REGION: $ITEM_COUNT"
  echo " "
}

## Executes the cfn change set and adds a delay to avoid errors
execute_change_set(){
  CHANGE_ARN=$1
  STACK_NAME=$2
  REGION=$3
  STEP=$4
  sleep 5
  echo "STEP $STEP Starting ChangeSet Execution"
  echo "Change ARN: $CHANGE_ARN"
  ## USE TO DESCIBE CHANGES FOR AUDITING
  #aws cloudformation describe-change-set --change-set-name $CHANGE_ARN
  aws cloudformation execute-change-set --change-set-name $CHANGE_ARN --region $REGION
  sleep 2
  check_execution_status "$STACK_NAME" "$REGION" "$STEP"
}

get_scaling_settings(){
  REGION=$1
  TABLE_NAME=$2
  WHEN=$3
  echo "$WHEN: Autoscaling Settings for $REGION:"
  ## THIS WON'T SHOW UNTIL AFTER THE REPLICA STEP
  aws dynamodb describe-table-replica-auto-scaling --table-name $TABLE_NAME --region $REGION
}

if [ $# -eq 0 ];then
  echo "NO input"
  EXE_STEP=$DEFAULT_STEP
else
  EXE_STEP=$1
  echo "Running Step ${EXE_STEP} for stack ${STACK_NAME}..."
fi

### STEP 1 : INITIAL CREATION
if [ $EXE_STEP == 1 ];then
  echo "STEP 1: Running initial build out of stack"
  aws cloudformation deploy \
    --template-file cloudformation-1-initial.yaml \
    --stack-name $STACK_NAME \
    --region $PRIMARY_REGION \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides DBTableName=$TABLE_NAME
fi

### STEP 2 : DELETION POLICY
if [ $EXE_STEP == 2 ];then
  echo "STEP 2: Add in deletion policy"
  CHANGE_ARN=$(aws cloudformation create-change-set \
    --template-body file://./cloudformation-2-deletionPolicy.yaml \
    --stack-name $STACK_NAME \
    --capabilities CAPABILITY_NAMED_IAM \
    --region $PRIMARY_REGION \
    --change-set-name create-retain \
    --query 'Id' \
    --output text \
    --parameters ParameterKey=DBTableName,ParameterValue=$TABLE_NAME)

  execute_change_set "$CHANGE_ARN" "$STACK_NAME" "$PRIMARY_REGION" "2"
  get_item_count "$TABLE_NAME" "$PRIMARY_REGION"
fi

### STEP 3 : Unmanage Table
if [ $EXE_STEP == 3 ];then
  echo "STEP 3: Unmanaging the dynamodb table"
  CHANGE_ARN=$(aws cloudformation create-change-set \
    --template-body file://./cloudformation-3-unmanage.yaml \
    --stack-name $STACK_NAME \
    --capabilities CAPABILITY_NAMED_IAM \
    --region $PRIMARY_REGION \
    --change-set-name unmanage-resources \
    --query 'Id' \
    --output text \
    --parameters ParameterKey=DBTableName,ParameterValue=$TABLE_NAME)

  execute_change_set "$CHANGE_ARN" "$STACK_NAME" "$PRIMARY_REGION" "3"
  get_item_count "$TABLE_NAME" "$PRIMARY_REGION"
fi

### STEP 4: Import Table as GlobalTable Resource 
if [ $EXE_STEP == 4 ];then
  echo "STEP 4: Creating ChangeSet for Import"

  CHANGE_ARN=$(aws cloudformation create-change-set \
    --stack-name $STACK_NAME \
    --change-set-name ImportChangeSet \
    --change-set-type IMPORT \
    --region $PRIMARY_REGION \
    --parameters ParameterKey=DBTableName,ParameterValue=$TABLE_NAME ParameterKey=PrimaryRegion,ParameterValue=$PRIMARY_REGION ParameterKey=ReplicaRegion,ParameterValue=$REPLICA_REGION \
    --resources-to-import "[ \
      {\"ResourceType\":\"AWS::DynamoDB::GlobalTable\",\"LogicalResourceId\":\"CfnTestPrices\", \"ResourceIdentifier\":{\"TableName\":\"$TABLE_NAME\"}}
      ]" \
    --template-body "file://$SCRIPT_DIR/cloudformation-4-import-table.yaml" --capabilities CAPABILITY_NAMED_IAM \
    --query 'Id' \
    --output text)

  execute_change_set "$CHANGE_ARN" "$STACK_NAME" "$PRIMARY_REGION" "4"
  get_item_count "$TABLE_NAME" "$PRIMARY_REGION"
fi

### STEP 5: Create Replica in REPLICA_REGION
if [ $EXE_STEP == 5 ];then
  echo "STEP 5: Create Replica in another region"
  CHANGE_ARN=$(aws cloudformation create-change-set \
    --template-body file://./cloudformation-5-create-replica.yaml \
    --stack-name $STACK_NAME \
    --capabilities CAPABILITY_NAMED_IAM \
    --region $PRIMARY_REGION \
    --change-set-name create-replica \
    --query 'Id' \
    --output text \
    --parameters ParameterKey=DBTableName,ParameterValue=$TABLE_NAME ParameterKey=PrimaryRegion,ParameterValue=$PRIMARY_REGION ParameterKey=ReplicaRegion,ParameterValue=$REPLICA_REGION)


  echo "NOTICE - This step can take up to 30 minutes depending on the table size."
  echo " "
  execute_change_set "$CHANGE_ARN" "$STACK_NAME" "$PRIMARY_REGION" "5"

  get_item_count "$TABLE_NAME" "$PRIMARY_REGION"
  get_item_count "$TABLE_NAME" "$REPLICA_REGION"

  get_scaling_settings "$PRIMARY_REGION" "$TABLE_NAME" "AFTER"
  get_scaling_settings "$REPLICA_REGION" "$TABLE_NAME" "AFTER"
fi

### STEP 6: Final Validation
if [ $EXE_STEP == 6 ];then
  echo "STEP 6: Change all scaling values in both regions"
  CHANGE_ARN=$(aws cloudformation create-change-set \
    --template-body file://./cloudformation-6-test-scaling.yaml \
    --stack-name $STACK_NAME \
    --capabilities CAPABILITY_NAMED_IAM \
    --region $PRIMARY_REGION \
    --change-set-name final-scaling-test \
    --query 'Id' \
    --output text \
    --parameters ParameterKey=DBTableName,ParameterValue=$TABLE_NAME ParameterKey=PrimaryRegion,ParameterValue=$PRIMARY_REGION ParameterKey=ReplicaRegion,ParameterValue=$REPLICA_REGION)

  get_scaling_settings "$PRIMARY_REGION" "$TABLE_NAME" "BEFORE"
  get_scaling_settings "$REPLICA_REGION" "$TABLE_NAME" "BEFORE"

  execute_change_set "$CHANGE_ARN" "$STACK_NAME" "$PRIMARY_REGION" "6"

  get_scaling_settings "$PRIMARY_REGION" "$TABLE_NAME" "AFTER"
  get_scaling_settings "$REPLICA_REGION" "$TABLE_NAME" "AFTER"
  
  get_item_count "$TABLE_NAME" "$PRIMARY_REGION"
  get_item_count "$TABLE_NAME" "$REPLICA_REGION"
fi

## DELETE
if [ $EXE_STEP == 86 ];then
  ## disables deletion protection for replica
  aws cloudformation deploy \
    --template-file cloudformation-7-remove.yaml \
    --stack-name $STACK_NAME \
    --region $PRIMARY_REGION \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides DBTableName=$TABLE_NAME ParameterKey=PrimaryRegion,ParameterValue=$PRIMARY_REGION ParameterKey=ReplicaRegion,ParameterValue=$REPLICA_REGION

  ### WAITING 
  sleep 5

  ##disables primary deletion protection and removes replica
  aws cloudformation deploy \
    --template-file cloudformation-8-remove.yaml \
    --stack-name $STACK_NAME \
    --region $PRIMARY_REGION \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides DBTableName=$TABLE_NAME ParameterKey=PrimaryRegion,ParameterValue=$PRIMARY_REGION ParameterKey=ReplicaRegion,ParameterValue=$REPLICA_REGION

  ### WAITING
  sleep 5

  echo "Deleting Stack $STACK_NAME with $TABLE_NAME..."
  aws cloudformation delete-stack --stack-name $STACK_NAME --region $PRIMARY_REGION
fi

echo "STEP $EXE_STEP COMPLETE"
