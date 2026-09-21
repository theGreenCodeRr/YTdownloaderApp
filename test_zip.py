import zipfile
import os

# Create dummy files
os.makedirs("test_dir", exist_ok=True)
with open("test_dir/1.txt", "w") as f: f.write("test")
with open("test_dir/2.txt", "w") as f: f.write("test2")

with zipfile.ZipFile("test.zip", 'w', zipfile.ZIP_DEFLATED) as zipf:
    for root, _, files in os.walk("test_dir"):
        for file in files:
            file_path = os.path.join(root, file)
            arcname = os.path.relpath(file_path, "test_dir")
            zipf.write(file_path, arcname)
            os.remove(file_path)

print(os.listdir("test_dir"))
print(os.path.exists("test.zip"))
