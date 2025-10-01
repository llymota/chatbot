# Docker Volume Backup⌛ :-

## VPS -> Local 🚀 ---------------------------------------------------------------------------------------------------------

### In VPS 
--->  docker volume ls
--->  docker volume inspect n8n_data
[
    {
        "CreatedAt": "2025-08-18T09:37:32Z",
        "Driver": "local",
        "Labels": null,
        "Mountpoint": "/var/lib/docker/volumes/n8n_data/_data",
        "Name": "n8n_data",
        "Options": null,
        "Scope": "local"
    }
]
<!-- Convert Docker volume folder to tar.gz | 'n8n_data': Docker Volume name -->
--->  sudo tar -czf n8n-backup.tar.gz -C /var/lib/docker/volumes/n8n_data/_data .

### In Local
<!-- Download tar.gz file -->
--->  scp root@31.97.235.130:~/n8n-backup.tar.gz ./n8n-backup.tar.gz

---> docker volume create n8n-backup

<!-- Copy local backup data to Docker Volume -->
--->  docker run --rm -v n8n-backup:/data -v $(pwd):/backup alpine sh -c "cd /data && tar xzf /backup/n8n-backup.tar.gz"


## Local -> VPS 🚀 ---------------------------------------------------------------------------------------------------------

### In Local
<!-- Create backup from your local Docker volume -->
--->  docker run --rm -v n8n-backup:/data -v $(pwd):/backup alpine tar czf /backup/n8n-local-backup.tar.gz -C /data .

<!-- Send tar file to Remote/host server -->
--->  scp ./n8n-local-backup.tar.gz root@31.97.235.130:~/n8n-local-backup.tar.gz

### In VPS
<!-- Verify if tar file come or not -->
--->  ls

<!-- Create new Docker Volume 'new-n8n-data' -->
--->  docker volume create new-n8n-data

<!-- Extract tar in new Docker Volume path -->
--->  sudo tar -xzf n8n-backup.tar.gz -C /var/lib/docker/volumes/new-n8n-data/_data/

<!-- Verify if extract tar properly -->
--->  cd /var/lib/docker/volumes/new-n8n-data/_data/

---> Change docker-compose file manually on VPS and Boom💥


## VPS -> VPS 🚀 ---------------------------------------------------------------------------------------------------------

### From VPS
<!-- Create tar file from Existing Docker Volume -->
--->  sudo tar -czf n8n-transfer-backup.tar.gz -C /var/lib/docker/volumes/n8n_data/_data .

<!-- Send tar file to targeted VPS -->
--->  scp n8n-transfer-backup.tar.gz root@destination-vps-ip:~/n8n-transfer-backup.tar.gz

### To VPS
<!-- Verify if tar file come or not -->
--->  ls

<!-- Create new Docker Volume 'new-n8n-data' -->
--->  docker volume create new-n8n-data

<!-- Extract tar in new Docker Volume path -->
--->  sudo tar -xzf n8n-backup.tar.gz -C /var/lib/docker/volumes/new-n8n-data/_data/

<!-- Verify if extract tar properly -->
--->  cd /var/lib/docker/volumes/new-n8n-data/_data/

---> Change docker-compose file manually on VPS and Boom💥