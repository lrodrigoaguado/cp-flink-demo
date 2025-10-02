#!/bin/bash

# File with the list of images
IMAGE_FILE="images.txt"
# KIND cluster name
KIND_CLUSTER="kind"

# Check if the images file exists
if [[ ! -f "$IMAGE_FILE" ]]; then
  echo "Error: File $IMAGE_FILE not found."
  exit 1
fi

# --- FUNCTIONS ---

download_images() {
  echo "--- Downloading images ---"
  while IFS= read -r IMAGE; do
    if [[ -n "$IMAGE" ]]; then
      echo "Downloading image: $IMAGE"
      docker pull "$IMAGE"
      IMAGE_NAME=$(echo "$IMAGE" | tr '/:' '_')
      echo "Saving image to ${IMAGE_NAME}.tar"
      docker save -o "${IMAGE_NAME}.tar" "$IMAGE"
    fi
  done < "$IMAGE_FILE"
  echo "--- Download finished ---"
}

load_images_to_kind() {
  echo "--- Loading images to KinD ---"
  while IFS= read -r IMAGE; do
    if [[ -n "$IMAGE" ]]; then
      IMAGE_NAME=$(echo "$IMAGE" | tr '/:' '_')
      if [[ -f "${IMAGE_NAME}.tar" ]]; then
        echo "Loading image into KIND: $IMAGE"
        kind load image-archive "${IMAGE_NAME}.tar" --name "$KIND_CLUSTER"
        echo "✔ Image $IMAGE loaded into KIND successfully."
      else
        echo "Warning: File ${IMAGE_NAME}.tar not found for image $IMAGE. Skipping."
      fi
    fi
  done < "$IMAGE_FILE"
  echo "--- KinD load finished ---"
  echo "----------------------------------"
  echo "📦 Image list in KIND:"
  docker exec -it $(docker ps -qf "name=kind-control-plane") crictl images
  echo "----------------------------------"
}

delete_images() {
  echo "--- Deleting images and .tar files ---"
  while IFS= read -r IMAGE; do
    if [[ -n "$IMAGE" ]]; then
      IMAGE_NAME=$(echo "$IMAGE" | tr '/:' '_')
      echo "Deleting file ${IMAGE_NAME}.tar"
      rm -f "${IMAGE_NAME}.tar"
      echo "Deleting Docker image: $IMAGE"
      docker rmi "$IMAGE"
    fi
  done < "$IMAGE_FILE"
  echo "--- Deletion finished ---"
}

# --- MAIN MENU ---

echo "Select an option:"
echo "1. Download images"
echo "2. Load images into KinD"
echo "3. Download and load into KinD"
echo "4. Delete images"
echo "5. Exit"

read -p "Option [1-5]: " choice

case $choice in
  1)
    download_images
    ;;
  2)
    load_images_to_kind
    ;;
  3)
    download_images
    load_images_to_kind
    ;;
  4)
    delete_images
    ;;
  5)
    echo "Exiting."
    exit 0
    ;;
  *)
    echo "Invalid option. Exiting."
    exit 1
    ;;
esac

echo "🎉 Process completed."
