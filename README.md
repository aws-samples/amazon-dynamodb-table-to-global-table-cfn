# Amazon DynamoDB converting table to global table with AWS CloudFormation

It is common to have policies in place to only allow changes via infrastructure as code (IaC) to ensure changes made on production environment are controlled. 
To provide additional resiliency to your applications, you can use Amazon DynamoDB global tables that is a fully managed, serverless, multi-active, and multi-Region database. 

### Using AWS console
To change a DynamoDB table to a global table via AWS console, you follow these steps: 
- Open AWS console and find your DynamoDB table: [https://console.aws.amazon.com/dynamodb](https://console.aws.amazon.com/dynamodb)
- Go to **Global tables** tab, and add a replica in another the AWS Region

If your table has provisioned capacity mode, auto scaling for write must be enabled on your table and its GSIs (if there are any).
If DynamoDB stream is not enabled for your table, it will automatically be enabled when you create a replica for your table via AWS console.

### Using AWS CloudFormation

If your infrastructure is managed via AWS CloudFormation, 
to change a DynamoDB table (AWS::DynamoDB::Table) to a global table (AWS::DynamoDB::GlobalTable) using only CloudFormation,
you **must** follow the instruction explained below.
This way, you protect your table from accidental deletion, as well as, possible negative impact on the performance of your table because of changing your table to a global table.

## About this repository

This repository walks you through the required steps to change the resource type of a DynamoDB table (with provisioned capacity mode and auto scaling enabled) in CloudFormation template from AWS::DynamoDB::Table to AWS::DynamoDB::GlobalTable.
The **global table (AWS::DynamoDB::GlobalTable) has version 2019.11.21**.

This example uses the AWS provided auto scaling role: aws-service-role/dynamodb.application-autoscaling.amazonaws.com/AWSServiceRoleForApplicationAutoScaling_DynamoDBTable. If you have your own role you can retain and use this role as well.

When running the steps explained below, check that you have sufficient permissions to run the commands in your own AWS account.

You find more information about each step (in form of comments) in the CloudFormation templates in this repository.
It is important to read the comments carefully to understand the changes happening in each step,
so that you make similar changes when running these steps on your own table(s).

## Before you begin

**To make this change safely on your DynamoDB table, it is immensely important to complete each step successfully before performing the next step.**
**Use the instruction explained below and the scripts in this repository as a guideline to build your own process.
Before making any changes on your table in your production environment, test the following instruction and scripts on a test table with the same configuration as your production table in your test environment.**

See, [additional information related to changing a DynamoDB table to global table](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-dynamodb-globaltable.html).

## Steps-by-step instruction

### Update Script (cfn-execution.sh)

This script helps you execute each of the commands bellow step by step.
Use this script as a base to create your own script to plan your change flow.
You can also use this to walk through each of the steps explained below.

Edit the script to customize your stack and table name in the script:
```
### OPTIONS
TABLE_NAME='cfnTestPrices'
STACK_NAME="cfn-demo-dynamodb"
DEFAULT_STEP=1
```

This command will execute step 1 from the steps listed below.
```./cfn-execution.sh 1 ## will execute step 1```

This command will delete the stack:
```./cfn-execution.sh 86```

The instructions starting below are assuming you are running this without the `cfn-execution.sh` script and default table values to illustrate the individual steps.

### STEP 1: Create an initial DynamoDB table

In a terminal using an AWS profile with sufficient permissions in your AWS account, run the following command to deploy the stack used here as an example.


```
aws cloudformation deploy \
  --template-file cloudformation-1-initial.yaml \
  --stack-name cfn-demo-dynamodb \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides DBTableName=cfnTestPrices
```

This step creates the initial table `cfnTestPrices` with a partition key called `price` and sort key called `date`.
Notice that `StreamSpecification` is set to `StreamViewType: KEYS_ONLY` in the initial table.
If DynamoDB stream is not enabled on this table, you get an error message when creating a replica in subsequent steps.

After the stack is deployed, open the AWS console for CloudFormation: [https://console.aws.amazon.com/cloudformation](https://console.aws.amazon.com/cloudformation), and find the stack called `cfn-demo-dynamodb`.

Check that you are in the same AWS Region, **N.Virgina (us-east-1)**, as the stack was deployed. 
Clicking on the name of the stack `cfn-demo-dynamodb`, shows details of deployed AWS resources in the stack.
In the following steps, you were asked to check the details of this stack and also view the change sets.

### STEP 2: Add deletion policy 

In this step, set `DeletionPolicy: Retain` for `AWS::DynamoDB::Table`, `AWS::ApplicationAutoScaling::ScalableTarget`, and `AWS::ApplicationAutoScaling::ScalingPolicy` resources. 
This ensures that no resources are deleted when you remove them from the CloudFormation template. 

Add `DeletionProtectionEnabled: true` to the DynamoDB table resource in the CloudFormation template.
[This property was released in March of 2023](https://aws.amazon.com/about-aws/whats-new/2023/03/amazon-dynamodb-table-deletion-protection/) and ensures that the table can not be deleted without the proper IAM permissions. 

`DeletionProtectionEnabled` attribute will be moved to the replica specification in step 4. 

Add `DisableScaleIn: False` explicitly in the `TableReadScalingPolicy` and `TableWriteScalingPolicy`. 
This ensures that those policies can be retained and adopted by the new global table resource. 
All the properties listed under `TableReadScalingPolicy` and `TableWriteScalingPolicy` are required for the CloudFormation to execute properly.

Create a CloudFormation change set. This allows to review the infrastructure changes before executing them. 

`MyEmptyResource` is added to the template to have at least one resource remaining in the template 
after the DynamoDB table and auto scaling resources are removed from the template.
CloudFormation deletes an empty template which in this process would result in an error. 

See, [Viewing a change set](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets-view.html)

#### Create CloudFormation change set

Run the following command in a terminal using an AWS profile with sufficient permissions in your AWS account in **us-east-1** AWS Region:

```
aws cloudformation create-change-set \
  --template-body file://./cloudformation-2-deletionPolicy.yaml \
  --stack-name cfn-demo-dynamodb \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1 \
  --change-set-name create-retain \
  --parameters ParameterKey=DBTableName,ParameterValue=cfnTestPrices 
```

#### ChangeSet Validation

Review this change set to ensure no resources are deleted or re-created.

The `describe-stack-events` command, as you see below, have a ResourceStatus of `UPDATE_COMPLETE` when the update has completed.

Run the following commands to validate the table, scalable target, and scalable policy created in step 1, were not modified in step 2.

```
## Validate that the changes being made are appropriate
aws cloudformation describe-change-set --change-set-name <Arn of Id from previous command>

## Execute the changeSet
aws cloudformation execute-change-set --change-set-name <Arn of Id from previous command>

## Wait until the change set finishes and is status UPDATE_COMPLETE
aws cloudformation describe-stack-events --stack-name cfn-demo-dynamodb --max-items 1

## Validate resources and creation time
aws dynamodb describe-table --table-name cfnTestPrices
aws application-autoscaling describe-scalable-targets --service-namespace dynamodb --resource-id "table/cfnTestPrices"
aws application-autoscaling describe-scaling-policies --service-namespace dynamodb --resource-id "table/cfnTestPrices"
```

### STEP 3: Unmanage table and auto scaling resources from CloudFormation

After `AWS::DynamoDB::Table`, `AWS::ApplicationAutoScaling::ScalableTarget`, and `AWS::ApplicationAutoScaling::ScalingPolicy` resources
are successfully protected from deletion in the previous step, remove them from the CloudFormation template so they are no longer managed by CloudFormation. 

Since we set the deletionPolicy to retain for all resources and enabled deletion protection for the dynamoDB table, the CloudFromation template will not delete any resources they will just become unmanaged within cloudformation. We will combine all of these policies into a single global table reosurce in the next step.
The only resource left behind will be the MyEmptyResource in order to prevent any cloudformation errors.


#### Create CloudFormation ChangeSet
```
aws cloudformation create-change-set \
  --template-body file://./cloudformation-3-unmanage.yaml \
  --stack-name cfn-demo-dynamodb \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1 \
  --change-set-name unmanage-resources \
  --parameters ParameterKey=DBTableName,ParameterValue=cfnTestPrices 
 ```

#### Review, Execute, and Validate CloudFormation ChangeSet
Same as previous steps.

```
aws cloudformation describe-change-set --change-set-name <Arn of Id from previous command>
aws cloudformation execute-change-set --change-set-name <Arn of Id from previous command>
aws cloudformation describe-stack-events --stack-name cfn-demo-dynamodb --max-items 1
aws dynamodb describe-table --table-name cfnTestPrices
aws application-autoscaling describe-scalable-targets --service-namespace dynamodb --resource-id "table/cfnTestPrices"
aws application-autoscaling describe-scaling-policies --service-namespace dynamodb --resource-id "table/cfnTestPrices"
aws dynamodb scan --table-name cfnTestPrices --select "COUNT"
```

### STEP 4: Import Existing AWS::DynamoDB::Table as a AWS::DynamoDB::GlobalTable

This step defines your existing table that we just unmanaged as a global table. 
You'll notice that the configurations for write auto-scaling is a definition of the global table and read auto-scaling is a definition of the replica within that global table. 
Read policies can differ between replicas, however write policies are shared between all replicas. 
This is because writes are needed to keep all replicas in sync with a low latency.

As an additional step, we are also moving the DeletionProtectionEnabled property to the replica portion of the cloudformation template as it is not supported as a general property of the global dynamodb resource.

Notice we are not adding back TableWriteCapacityScalableTarget, TableWriteScalingPolicy, ScalingRole, ScalingRolePolicy. The functionality that those attribute provide are now part of the dynamodb global table resource itself and retained in the import process.


#### Create Cloudformation ChangeSet
```
aws cloudformation create-change-set \
  --stack-name cfn-demo-dynamodb \
  --change-set-name ImportChangeSet \
  --change-set-type IMPORT \
  --region us-east-1 \
  --resources-to-import "[ \
    {\"ResourceType\":\"AWS::DynamoDB::GlobalTable\",\"LogicalResourceId\":\"cfnTestPrices\",\"ResourceIdentifier\":{\"TableName\":\"cfnTestPrices\"}}
  ]" \
  --template-body file://./cloudformation-4-import-table.yaml \
  --parameters ParameterKey=DBTableName,ParameterValue=cfnTestPrices \
  --capabilities CAPABILITY_NAMED_IAM
```

#### Review / Execute / Validate ChangeSet and Items
```
aws cloudformation describe-change-set --change-set-name <Arn of Id from previous command>
aws cloudformation execute-change-set --change-set-name <Arn of Id from previous command>
aws cloudformation describe-stack-events --stack-name cfn-demo-dynamodb --max-items 1
aws dynamodb describe-table --table-name cfnTestPrices
aws application-autoscaling describe-scalable-targets --service-namespace dynamodb --resource-id "table/cfnTestPrices"
aws application-autoscaling describe-scaling-policies --service-namespace dynamodb --resource-id "table/cfnTestPrices"
aws dynamodb scan --table-name cfnTestPrices --select "COUNT"
```

### STEP 5: Create Replica in Another Region
In this step we are adding a replica in us-east-2.
After this step we can do additional validation to ensure scaling policies are correct and the replica exists in the second region. 
This step can take up to an hour to complete based on the size of the table. 
If you are looking at moving a large table in the GB - TB range, work with your AWS account team to ensure that this will be successful. 
In this example the cloudformation execution should take near 10 minutes.

#### Create Cloudformation ChangeSet
```
aws cloudformation create-change-set \
  --template-body file://./cloudformation-5-create-replica.yaml \
  --stack-name cfn-demo-dynamodb \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters ParameterKey=DBTableName,ParameterValue=cfnTestPrices \
  --region us-east-1 \
  --change-set-name add-replica
```

#### Review / Execute / Validate ChangeSet and Items
```
aws cloudformation describe-change-set --change-set-name <Arn of Id from previous command>
aws cloudformation execute-change-set --change-set-name <Arn of Id from previous command>
aws cloudformation describe-stack-events --stack-name cfn-demo-dynamodb --max-items 1
```

#### Verify New Replica and Item Count In both regions:
```
aws dynamodb describe-table --table-name cfnTestPrices --region us-east-1
aws dynamodb describe-table --table-name cfnTestPrices --region us-east-2
aws dynamodb scan --table-name cfnTestPrices --select "COUNT" --region us-east-1
aws dynamodb scan --table-name cfnTestPrices --select "COUNT" --region us-east-2
```

#### Verify scaling policies for global table in both regions
```
aws dynamodb describe-table-replica-auto-scaling --table-name cfnTestPrices --region us-east-1
aws dynamodb describe-table-replica-auto-scaling --table-name cfnTestPrices --region us-east-2
```

### STEP 6: Change all scaling policies (optional)
In this optional step, we will change all the scaling policies to ensure that everything is working as expected as a last validation.

#### Create Cloudformation ChangeSet
```
aws cloudformation create-change-set \
  --template-body file://./cloudformation-6-test-scaling.yaml \
  --stack-name cfn-demo-dynamodb \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters ParameterKey=DBTableName,ParameterValue=cfnTestPrices \
  --region us-east-1 \
  --change-set-name change-scaling
```

#### Review / Execute / Validate ChangeSet and Items
```
aws cloudformation describe-change-set --change-set-name <Arn of Id from previous command>
aws cloudformation execute-change-set --change-set-name <Arn of Id from previous command>
aws cloudformation describe-stack-events --stack-name cfn-demo-dynamodb --max-items 1
```

#### Verify New Replica and Item Count In both regions:
```
aws dynamodb scan --table-name cfnTestPrices --select "COUNT" --region us-east-1
aws dynamodb scan --table-name cfnTestPrices --select "COUNT" --region us-east-2
```

#### Verify scaling policies for global table in both regions
```
aws dynamodb describe-table-replica-auto-scaling --table-name cfnTestPrices --region us-east-1
aws dynamodb describe-table-replica-auto-scaling --table-name cfnTestPrices --region us-east-2
```

### Clean Up The Stack for Demo
In order to execute this cleanly, you will need to either update the cloudformation stack to have DeletionProtectionEnabled: false OR in the console disable deletion protection on the table you've created 'cfn-demo-dynamodb'.

```
## disables deletion protection on replica
aws cloudformation deploy \
    --template-file cloudformation-7-remove.yaml \
    --stack-name cfn-demo-dynamodb \
    --region us-east-1 \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides DBTableName=cfnTestPrices

## deletes replica / disables deletion protection on primary
aws cloudformation deploy \
  --template-file cloudformation-8-remove.yaml \
  --stack-name cfn-demo-dynamodb \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides DBTableName=cfnTestPrices

## deletes table and stack
aws cloudformation delete-stack --stack-name cfn-demo-dynamodb
```

OR (if you have configured your stack and database name in the script):

```
./cfn-execution 86
```

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
