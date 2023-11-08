# DynamoDB Converting Table to Global Table with CloudFormation

## About This Repo
Many customers have security policies in their organization to only make changes via infrastructure as code to ensure users only have controlled access to production environments. In an effort to provide additional resiliency to their applications, they are looking to embrace the use of DynamoDB Global Tables. In the console, it is relatively easy to convert a dynamodb table to a global table. It only requires the creation of a replica. However, when making these changes strictly with cloudformation, this process is more difficult to do without impacting your auto scaling, running into errors, or at worst losing your entire database. The steps in this document are to ensure that you can safely make this transition without impacting your production database from a scaling, availability, or data standpoint.

WARNING!
Use these steps with caution. If you do not follow these steps properly you may delete your dynamoDB Table.
Use these steps (or script) as a guidline to build your own process and test on non-production systems before executing on production workloads.

Additional documentation on this process and limitations can be found here: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-dynamodb-globaltable.html

This repo contains steps to update a dynamodb table stored in CloudFormation to a global table (version 2019.11.21) without recreating the table.

The specific scenario illustrates how to convert an existing dynamoDB regional table that is provisioned and has autoscaling enabled to a global table resource with a replica in another region. This is all done without having to create a new dynamoDB table or incuring any downtime. Use these steps as a guide to create your own change steps and testing.

This example is also using the AWS provided autoscaling role: aws-service-role/dynamodb.application-autoscaling.amazonaws.com/AWSServiceRoleForApplicationAutoScaling_DynamoDBTable. If you have your own role you can retain and use this role as well.

This repository contains a series of CloudFormation templates that walk you through the steps that can update your CloudFormation in series to retain the table and convert it to a global table. 

These steps assume you have the permissions to run these commands. 
Comments within the CloudFormation files themselves explain the changes that are implimented from file to file.
Reading these comments will help you fully understand the scope of changes.

## Steps to Upgrade Table

### Update Script (cfn-execution.sh)

This script can help you execute each of the commands bellow step by step.
Use this script as a base to create your own to plan your change flow.
You can also use this to walk through each of the steps we discuss below.

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

The instructions starting below are assuming you are running this without the cfn execution script and default table values to illustrate the individual steps.

### STEP 1: Create an Initial DynamoDB Table

This step will create the initial table cfnTestPrices with a Primary Key of price and Secondary Key of date.
After this is created you will see it within the CloudFormation console under 'cfn-demo-dynamodb'.
You can reach the CloudFormation Console by typing 'cloudformation' in the search bar within the AWS console and selecting CloudFormation.
Ensure that you have the correct region in the dropdown as N.Virgina (us-east-1). Clicking on the name of the stack 'cfn-demo-dynamodb', will bring you to details of the stack.
Later, we will go here to view our change sets.

Notice that StreamSpecification: is set to StreamViewType: "KEYS_ONLY" in the intial table. 
If streams are not enabled on the table, you will observe a failure when creating a replica in subsequent steps.

```
aws cloudformation deploy \
  --template-file cloudformation-1-initial.yaml \
  --stack-name cfn-demo-dynamodb \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides DBTableName=cfnTestPrices
```

### STEP 2: Add Deletion Policy 

In this step we are setting a DeletionPolicy to retain. This ensures that no resources are deleted when we remove them from the cloudformation template. In order to for this to take effect with the TableReadCapacityScalableTarget and TableWriteCapictyScaleTarget, we are modifying the maxCapacity from 20 to 19. This is becasue if we don't make this change, cloudformation will not attribute deletionPolicy: retain as an change to the infrastructure and thus not change the resource. Additionally, we are adding DeletionProtectionEnabled: true to the dynamodb table resource itself. [This property was released in March of 2023](https://aws.amazon.com/about-aws/whats-new/2023/03/amazon-dynamodb-table-deletion-protection/) and ensures that the table can not be deleted without the proper IAM permissions. Notice we are putting this under the dynamodb table resource. This attribute will be moved to the replica specification in step 4. We also add disableScaleIn: False explictly in the tableReadScalingPolicy and tableWriteScaling policy. This ensures that those policies can be retained and adopted by our new global table resource. All of the properties listed under tableReadScalingPolicy and tableWriteScalingPolicy are required for the cloudformation to execute properly.

We will create a CloudFormation change set. This will allow us to review our infrastructure changes before executing them. 

We also add MyEmptyResource. This is so that when we unmanage the table and delete the scaling policy, we have at least one resource left in our cloudformation template in order to avoid having an empty cloudformation template that would result in an error.

We will be executing this change as a ChangeSet.

Here is more documentation on viewing a ChangeSet: https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets-view.html

#### Create CloudFormation ChangeSet
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
Look throught this change set to ensure no resources are deleted or re-created.
The describe-stack-events command will have a ResourceStatus of 'UPDATE_COMPLETE' when the update has completed.
You can validate the table and scalable target and scalable policy were created and not modified running the following commands.
If you are doing this on an existing table, you can also validate your item count.

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

## Validate Table Item Count (optional)
aws dynamodb scan --table-name cfnTestPrices --select "COUNT"
```

### STEP 3: Unmanage All Resources from CloudFormation

In this step, we are removing the management of all resources within the cloudformation template. Since we set the deletionPolicy to retain for all resources and enabled deletion protection for the dynamoDB table, the CloudFromation template will not delete any resources they will just become unmanaged within cloudformation. We will combine all of these policies into a single global table reosurce in the next step.
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

### STEP 4: Import Existing dynamodn:table as a dynamodb:GlobalTable

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