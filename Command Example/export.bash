cd ~/projects/n8n_learning

# 1. Create the folder manually (Docker will use it)
mkdir -p n8n_data

# 2. Now the backup works perfectly
docker compose exec n8n n8n export:workflow --all --pretty \
  > n8n_data/workflows-$(date +%Y-%m-%d-%H%M).json

docker compose exec n8n n8n export:credentials --all --decrypted --pretty \
  > n8n_data/credentials-$(date +%Y-%m-%d-%H%M).json

# 3. See your files
ls -lh n8n_data/