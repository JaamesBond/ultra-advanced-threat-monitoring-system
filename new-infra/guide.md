# 1. Transit Gateway (shared)                                                                     
    cd new-infra/shared transit-gateway                                                               
    terraform init && terraform apply                                                                 
                                                                                                      
# 2. XDR VPC (creates the spoke-rt static default route)                                          
    cd new-infra/environments/bc-xdr/eu-central-1                                                     
    terraform init && terraform apply                                                                 
                                                                                                      
# 3. Control Plane VPC                                                                            
    cd new-infra/environments/bc-ctrl/eu-central-1                                                    
    terraform init && terraform apply

# 4. Production VPC
    cd new-infra/environments/bc-prd/eu-central-1
    terraform init && terraform apply

Steps 3 and 4 can run in parallel once step 2 is done. Step 1 must always be first.