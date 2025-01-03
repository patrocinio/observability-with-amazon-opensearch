#!/bin/bash

# Env Vars
export ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
export TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
export AWS_REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s 169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')

aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# obtain OSIS endpoints
export OSIS_TRACES_URL=$(aws osis get-pipeline --pipeline-name osi-pipeline-oteltraces | jq -r '.Pipeline.IngestEndpointUrls[0]')
export OSIS_LOGS_URL=$(aws osis get-pipeline --pipeline-name osi-pipeline-otellogs | jq -r '.Pipeline.IngestEndpointUrls[0]')
export OSIS_METRICS_URL=$(aws osis get-pipeline --pipeline-name osi-pipeline-otelmetrics | jq -r '.Pipeline.IngestEndpointUrls[0]')

# Changing directory to build inside the application folders
cd ..

#configure OSIS endpoints and region
sed -i -e "s/__REPLACE_WITH_OtelTraces_ENDPOINT__/${OSIS_TRACES_URL}/g" sample-apps/02-otel-collector/kubernetes/01-configmap.yaml
sed -i -e "s/__REPLACE_WITH_OtelLogs_ENDPOINT__/${OSIS_LOGS_URL}/g" sample-apps/02-otel-collector/kubernetes/01-configmap.yaml
sed -i -e "s/__REPLACE_WITH_OtelMetrics_ENDPOINT__/${OSIS_METRICS_URL}/g" sample-apps/02-otel-collector/kubernetes/01-configmap.yaml
sed -i -e "s/__AWS_REGION__/${AWS_REGION}/g" sample-apps/02-otel-collector/kubernetes/01-configmap.yaml

push_images_s3() {
    echo "Building ${2} ..."
    service_folder=$1
    repo_name=$2
    cd sample-apps/$service_folder/
    echo $PWD # Check Directory
    zip -rq $repo_name.zip *
    aws s3 cp $repo_name.zip s3://codebuild-assets-$AWS_REGION-$ACCOUNT_ID/
    rm $repo_name.zip
    sed -i -e "s/__ACCOUNT_ID__/${ACCOUNT_ID}/g" kubernetes/01-deployment.yaml
    sed -i -e "s/__AWS_REGION__/${AWS_REGION}/g" kubernetes/01-deployment.yaml
    rm -rf kubernetes/01-deployment.yaml-e
    sleep 10
    build=$(aws codebuild start-build --project-name $repo_name)
    cd ../..
}

check_build_status() {
    # Get all project names
    projects=$(aws codebuild list-projects --output text --query 'projects[*]')
    myArray=()
    for project in $projects; do
        myArray+=($project)
    done
    # Loop through each project
    status="NA"
    while [ ${#myArray[@]} -gt 0 ]; 
    do
        message="Building: "
        newProjects=()
        for project in ${myArray[@]}; do
            # Get the most recent builds for this project
            builds=$(aws codebuild list-builds-for-project --project-name "$project" --output text --query 'ids[*]')
            
            # Get detailed build information
            status=$(aws codebuild batch-get-builds --ids $builds --query 'builds[*].[buildStatus]' --output text)
            if [[ "$status" != SUCCEEDED* ]] then
                message+="$project "
                newProjects+=("$project") 
            fi  
        done
        myArray=("${newProjects[@]}")
        echo -ne "\n$message"
        sleep 10
    done
    echo "Build complete"
}

push_images_s3 '04-analytics-service' 'analytics-service'
push_images_s3 '05-databaseService' 'database-service'
push_images_s3 '06-orderService' 'order-service'
push_images_s3 '07-inventoryService' 'inventory-service'
push_images_s3 '08-paymentService' 'payment-service'
push_images_s3 '09-recommendationService' 'recommendation-service'
push_images_s3 '10-authenticationService' 'authentication-service'
push_images_s3 '11-client' 'client-service'

check_build_status