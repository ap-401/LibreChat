import * as documentDb from 'aws-cdk-lib/aws-docdb';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import { defineBackend } from '@aws-amplify/backend';

const backend = defineBackend({});

const customResourceStack = backend.createStack('DocumentDbCustomResources');

// Create a new VPC to deploy the document DB server with subnets
const LibreChatVpc = new ec2.Vpc(customResourceStack, 'LibreChatVpc', {
  vpcName: 'LibreChatVpc',
  ipAddresses: ec2.IpAddresses.cidr('10.0.0.0/16'),
  subnetConfiguration: [
    {
       cidrMask: 26,
       name: 'data-subnet-1',
       subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
     },
     {
       cidrMask: 26,
       name: 'data-subnet-2',
       subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
     }
  ]
});
// Create the Document DB cluster in the VPC
new documentDb.DatabaseCluster(customResourceStack, 'LibreChatDatabase', {
  masterUser: {
    username: 'libreAdmin',
  },
  vpc: LibreChatVpc,
  serverlessV2ScalingConfiguration: {
    minCapacity: 0.5,
    maxCapacity: 1,
  },
  engineVersion: '5.0.0', // Serverless requires engine version 5.0.0 or higher
});