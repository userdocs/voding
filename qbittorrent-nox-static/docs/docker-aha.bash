#!/bin/bash

# Clean up any existing container
docker rm -f aha_html 2> /dev/null || true

# Create Alpine container with volume mount for scripts (keep alive with tail)
docker run -dit --name aha_html -w /workspace -v "$(pwd):/workspace" alpine:edge tail -f /dev/null

# Wait for container to be ready
sleep 2

# Update and install aha in container
printf '%s\n' "Updating Alpine packages..."
docker exec aha_html apk update

printf '%s\n' "Installing aha package..."
docker exec aha_html apk add --no-cache aha bash

wget -q "https://raw.githubusercontent.com/userdocs/qbittorrent-nox-static/refs/heads/master/qbt-nox-static.bash"

# Make scripts executable on host
chmod +x "aha.bash" "qbt-nox-static.bash"

# Check if aha.bash exists
if [ -f "aha.bash" ]; then
	printf '%s\n' "Executing aha.bash script..."
	docker exec -w /workspace aha_html bash aha.bash stage1
	docker exec -w /workspace aha_html bash qbt-nox-static.bash install_test
	docker exec -w /workspace aha_html bash aha.bash stage2
	docker exec -w /workspace aha_html bash qbt-nox-static.bash install_core
	docker exec -w /workspace aha_html bash aha.bash stage3
else
	printf '%s\n' "aha.bash not found, testing aha tool with sample output..."
	docker exec aha_html sh -c 'printf "%b\n" "\033[31mRed\033[0m \033[32mGreen\033[0m \033[34mBlue\033[0m" | aha'
fi

# Clean up container
printf '%s\n' "Cleaning up container..."
docker rm -f aha_html
