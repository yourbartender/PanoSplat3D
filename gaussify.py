#!/usr/bin/env python3
import math, os, sys
import numpy as np
from PIL import Image
import py360convert

def rotmat_to_qvec(R):
    Rxx, Ryx, Rzx, Rxy, Ryy, Rzy, Rxz, Ryz, Rzz = R.flat
    K = np.array([
        [Rxx - Ryy - Rzz, 0, 0, 0],
        [Ryx + Rxy, Ryy - Rxx - Rzz, 0, 0],
        [Rzx + Rxz, Rzy + Ryz, Rzz - Rxx - Ryy, 0],
        [Ryz - Rzy, Rzx - Rxz, Rxy - Ryx, Rxx + Ryy + Rzz]
    ]) / 3.0
    eigvals, eigvecs = np.linalg.eigh(K)
    qvec = eigvecs[[3, 0, 1, 2], np.argmax(eigvals)]
    if qvec[0] < 0:
        qvec *= -1
    return qvec

def write_init_ply(pano, out_path, num_points=15000, radius=5.0):
    h, w, _ = pano.shape
    rng = np.random.default_rng(42)
    u = rng.uniform(0.0, 1.0, num_points)
    v = rng.uniform(0.0, 1.0, num_points)

    # Spherical angles matching py360convert equirectangular layout
    lon = (u - 0.5) * 2.0 * math.pi
    lat = (0.5 - v) * math.pi

    # World coordinates (+X right, +Y down, +Z forward in COLMAP convention)
    x = radius * np.cos(lat) * np.sin(lon)
    y = -radius * np.sin(lat)
    z = radius * np.cos(lat) * np.cos(lon)

    px = np.clip((u * (w - 1)).astype(int), 0, w - 1)
    py = np.clip((v * (h - 1)).astype(int), 0, h - 1)
    rgb = pano[py, px]

    with open(out_path, "w") as f:
        f.write("ply\nformat ascii 1.0\n")
        f.write(f"element vertex {num_points}\n")
        f.write("property float x\nproperty float y\nproperty float z\n")
        f.write("property uchar red\nproperty uchar green\nproperty uchar blue\n")
        f.write("end_header\n")
        for i in range(num_points):
            f.write(f"{x[i]:.4f} {y[i]:.4f} {z[i]:.4f} {rgb[i,0]} {rgb[i,1]} {rgb[i,2]}\n")

def slice_panorama_for_brush(pano_path, out_dir, fov=90, size=1024):
    img_dir = os.path.join(out_dir, "images")
    sparse_dir = os.path.join(out_dir, "sparse", "0")
    os.makedirs(img_dir, exist_ok=True)
    os.makedirs(sparse_dir, exist_ok=True)

    pano = np.array(Image.open(pano_path).convert("RGB"))
    fl = 0.5 * size / math.tan(math.radians(fov) / 2.0)

    # 1. Write spherical initial point cloud so Brush starts with visible splats
    write_init_ply(pano, os.path.join(out_dir, "init.ply"))

    # 2. Write COLMAP cameras.txt (SIMPLE_PINHOLE)
    with open(os.path.join(sparse_dir, "cameras.txt"), "w") as f:
        f.write("# Camera list with one line of data per camera:\n")
        f.write(f"1 SIMPLE_PINHOLE {size} {size} {fl:.6f} {size/2.0:.6f} {size/2.0:.6f}\n")

    # 3. Render 24 perspective views and write COLMAP images.txt
    ring_configs = [(0, 8), (45, 8), (-45, 8)]
    idx = 1
    with open(os.path.join(sparse_dir, "images.txt"), "w") as f:
        f.write("# Image list with two lines of data per image:\n")
        for pitch, count in ring_configs:
            for i in range(count):
                yaw = (360.0 / count) * i
                persp = py360convert.e2p(
                    pano, fov_deg=(fov, fov), u_deg=yaw, v_deg=pitch,
                    out_hw=(size, size), mode="bilinear"
                )
                fname = f"view_{idx-1:03d}.png"
                Image.fromarray(persp).save(os.path.join(img_dir, fname))

                # World-to-camera rotation matching spherical point cloud
                y_rad, p_rad = math.radians(yaw), math.radians(pitch)
                Ry = np.array([
                    [ math.cos(y_rad), 0, -math.sin(y_rad)],
                    [ 0,               1,  0],
                    [ math.sin(y_rad), 0,  math.cos(y_rad)]
                ])
                Rx = np.array([
                    [1,  0,                0],
                    [0,  math.cos(p_rad),  math.sin(p_rad)],
                    [0, -math.sin(p_rad),  math.cos(p_rad)]
                ])
                R_w2c = Rx @ Ry
                qvec = rotmat_to_qvec(R_w2c)
                f.write(f"{idx} {qvec[0]:.8f} {qvec[1]:.8f} {qvec[2]:.8f} {qvec[3]:.8f} 0.0 0.0 0.0 1 {fname}\n\n")
                idx += 1

    # Empty points3D.txt (Brush will use init.ply)
    open(os.path.join(sparse_dir, "points3D.txt"), "w").close()
    print(f"Done! Created COLMAP dataset + 15,000-point init.ply in {out_dir}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: ./gaussify.py <input_panorama.png> <output_dir>")
        sys.exit(1)
    slice_panorama_for_brush(sys.argv[1], sys.argv[2])
