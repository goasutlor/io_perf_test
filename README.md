# IO Performance Sweep & Comparison Report

เครื่องมือวัดประสิทธิภาพ IO แบบ sweep **jobs 1→N** ด้วย [fio](https://github.com/axboe/fio) แล้วส่งออกเป็น **CSV** สำหรับเปิดเปรียบเทียบสองระบบในเบราว์เซอร์ผ่าน **`io_compare.html`** (ไม่ต้องติดตั้งเซิร์ฟเวอร์)

Repository: [https://github.com/goasutlor/io_perf_test](https://github.com/goasutlor/io_perf_test)

---

## ภาพรวมกระบวนการ (Workflow)

```mermaid
flowchart LR
  A[ติดตั้ง prerequisite] --> B[รัน io_sweep.sh]
  B --> C[sweep_results.csv + JSON/LOG ต่อ step]
  C --> D[เปิด io_compare.html]
  D --> E[อัปโหลด CSV 2 ชุด]
  E --> F[กราฟ + ตาราง + สรุปเปรียบเทียบ]
```

1. **Linux (แนะนำ root)** — รัน `io_sweep.sh` บน path ที่ต้องการทดสอบ  
2. **ผลลัพธ์** — ไฟล์ `sweep_results.csv` อยู่ในโฟลเดอร์ `io_sweep_<timestamp>/`  
3. **รายงานเว็บ** — เปิด `io_compare.html` ในเบราว์เซอร์ แล้วอัปโหลด CSV จาก System A / System B เพื่อดูกราฟและวิเคราะห์

---

## Prerequisites (ข้อกำหนดเบื้องต้น)

สคริปต์ตรวจสอบอัตโนมัติตอนเริ่มรัน (`check_prerequisites`)

| รายการ | จำเป็น? | หน้าที่หลัก | การติดตั้งตัวอย่าง |
|--------|---------|-------------|-------------------|
| **fio** | จำเป็น | เครื่องมือ benchmark IO | `yum install fio` / `apt install fio` / `brew install fio` |
| **python3** | จำเป็น | แปลงผล JSON จาก fio → คอลัมน์ CSV | `yum install python3` / `apt install python3` |
| **libaio** | แนะนำ | ใช้ ioengine `libaio` (async) | `yum install libaio libaio-devel` / `apt install libaio1 libaio-dev` — ถ้าไม่มี สคริปต์สลับเป็น `psync` |
| **sysstat** | ไม่บังคับ | มี `iostat` (fio รายงาน util% ใน JSON ได้เองอยู่แล้ว) | `yum install sysstat` / `apt install sysstat` |
| **util-linux** | ไม่บังคับ | `sync`, `blockdev` (พื้นฐานของระบบ) | มักมีอยู่แล้ว |
| **tput** | ไม่บังคับ | หาความกว้างเทอร์มินัล | มักมีอยู่แล้ว (ncurses) |
| **สิทธิ root** | แนะนำ | `echo 3 > /proc/sys/vm/drop_caches` ระหว่าง step | รันด้วย `sudo ./io_sweep.sh` |

**ติดตั้งแบบรวบเดียว (ตัวอย่าง):**

- RHEL / Rocky / AlmaLinux:  
  `yum install -y fio python3 libaio libaio-devel sysstat`
- Ubuntu / Debian:  
  `apt install -y fio python3 libaio1 libaio-dev sysstat`
- macOS:  
  `brew install fio python3` (ไม่มี libaio — ใช้ ioengine แบบ sync อัตโนมัติ)

---

## Features / Functions (สรุปจาก Shell Script)

### ฟีเจอร์หลัก

- **Sweep แบบ jobs 1→N** — ทดสอบทีละ job จาก 1 ถึง `MAX_JOBS` เพื่อหาจุดที่ throughput/latency สมดุลกับระบบจริง  
- **ลดผลจาก cache** — ไฟล์ทดสอบไม่ซ้ำต่อ step, **O_DIRECT** (`--direct`), `--invalidate=1`, **drop_caches** (เมื่อเป็น root), หน่วงเวลา settle, ลบไฟล์หลังจบ step  
- **เมนูอินเทอร์แอคทีฟ** — เลือก path, workload (randwrite/randread/read/write/randrw), block size, max jobs, iodepth, duration, ขนาดไฟล์ต่อ job, เปิด/ปิด Direct IO  
- **CSV แบบ rich** — มี bandwidth, IOPS, latency (avg, p50–p999, max), CPU, io util, context switches, profile, engine, timestamp  
- **สรุปท้ายรัน** — หา “sweet spot” (ค่าประมาณจาก Python อ่าน CSV) และแสดงตารางสถานะต่อ job (เช่น OK / HIGH LAT / SATURATED)

### ฟังก์ชันสำคัญใน `io_sweep.sh` (หน้าที่โดยย่อ)

| ฟังก์ชัน | หน้าที่ |
|---------|---------|
| `check_prerequisites` | ตรวจ fio, python3, libaio, sysstat, tput, และ privilege |
| `detect_ioengine` | เลือก `libaio` หรือ fallback `psync` |
| `run_menu` | รวบรวมพารามิเตอร์จากผู้ใช้ |
| `drop_caches` | sync + drop page cache (ถ้าเป็น root) |
| `parse_json_rich` | แปลง JSON ของ fio → ตัวเลขสำหรับหนึ่งแถวใน CSV |
| `run_one_step` | รัน fio หนึ่ง step, progress bar, parse, append CSV |
| `run_sweep` | สร้างโฟลเดอร์, header CSV, วน jobs 1..N |
| `print_summary` | สรุปผลและชี้ sweet spot |

### รูปแบบไฟล์ผลลัพธ์

- **`sweep_results.csv`** — ใช้กับ `io_compare.html` โดยตรง  
- **`step_j<N>.json`** — ผลดิบจาก fio ต่อแต่ละ job  
- **`step_j<N>.log`** — stderr ของ fio ต่อ step (ใช้ debug)

### Header ของ CSV (ตัวอย่าง)

```text
jobs,total_qd,bw_mbs,iops,bw_min_mbs,bw_max_mbs,bw_stdev_mbs,lat_avg_ms,lat_p50_ms,lat_p95_ms,lat_p99_ms,lat_p999_ms,lat_max_ms,lat_stdev_ms,slat_avg_us,clat_avg_us,cpu_usr_pct,cpu_sys_pct,io_util_pct,ctx_switches,profile,engine,file_size,timestamp
```

---

## การใช้งาน (Usage)

```bash
chmod +x io_sweep.sh
sudo ./io_sweep.sh    # แนะนำ — มี drop_caches ระหว่าง step
# ./io_sweep.sh       # ไม่ใช่ root — ยังรันได้ แต่ไม่ drop cache
```

หลังจบการรัน สคริปต์จะบอก path ของ `sweep_results.csv` และแนะนำให้เปิด **`io_compare.html`** เพื่ออัปโหลด CSV

### รายงานเว็บ (`io_compare.html`)

- เปิดไฟล์ในเบราว์เซอร์ (double-click หรือ `file:///.../io_compare.html` — ไม่ต้องมี backend)
- ตั้งชื่อ **System A** / **System B** (เช่น NVMe vs iSCSI)
- ลากหรือเลือกไฟล์ **`sweep_results.csv`** สองชุด
- กดปุ่มรันรายงาน — จะได้กราฟ IOPS, latency, สรุปเปรียบเทียบ และตารางตัวเลข

---

## ตัวอย่างจากโปรเจกต์นี้

### ตัวอย่างบรรทัดจาก `io_sweep.sh` (เมนู workload)

```bash
  echo "   1) randwrite   Random write ← recommended (DB/VM worst case)"
  echo "   2) randread    Random read  (DB query pattern)"
  echo "   3) read        Sequential read  (throughput test)"
  echo "   4) write       Sequential write (throughput test)"
  echo "   5) randrw      Mixed 70R/30W (OLTP simulation)"
```

### ตัวอย่างบรรทัดจาก `sweep_results_1.csv`

```csv
jobs,total_qd,bw_mbs,iops,bw_min_mbs,bw_max_mbs,bw_stdev_mbs,lat_avg_ms,lat_p50_ms,lat_p95_ms,lat_p99_ms,lat_p999_ms,lat_max_ms,lat_stdev_ms,slat_avg_us,clat_avg_us,cpu_usr_pct,cpu_sys_pct,io_util_pct,ctx_switches,profile,engine,file_size,timestamp
1,32,348.77,89285,277.82,377.26,22.76,0.3581,0.3338,0.514,0.7496,2.0562,12.6718,0.1424,3.768,354.298,6.47,36.55,99.68,559600,rw=randwrite bs=4k iodepth=32 direct=1 dur=30s,libaio,1g,20260330T093315
2,64,419.06,107279,309.28,457.14,15.11,0.5962,0.5693,0.8806,1.1223,2.5723,9.2667,0.195,5.334,590.832,3.79,27.04,99.77,970731,rw=randwrite bs=4k iodepth=32 direct=1 dur=30s,libaio,1g,20260330T093349
```

### ตัวอย่างหน้าจอเทอร์มินัล (สรุป)

สคริปต์แสดง banner, การยืนยันค่า (path, workload, sweep 1→N, iodepth, duration, ขนาดไฟล์, Direct IO, engine), แล้วรันแต่ละ STEP พร้อม progress bar และสรุป Throughput / IOPS / Latency ต่อ step — ดูตัวอย่างข้อความเต็มได้ในไฟล์ **`Example Result.txt`** ใน repo นี้

### ตัวอย่างผลลัพธ์เว็บ (HTML Report)

หน้าจอรายงานเปรียบเทียบหลังอัปโหลด CSV สองชุด:

![IO Comparison Report — overview](Screenshot%202026-03-30%20095752.png)

![IO Comparison Report — charts/detail](Screenshot%202026-03-30%20095817.png)

---

## โครงสร้างไฟล์ใน Repository

| ไฟล์ | คำอธิบาย |
|------|-----------|
| `io_sweep.sh` | สคริปต์หลัก sweep + สร้าง CSV |
| `io_compare.html` | รายงานเว็บเปรียบเทียบสอง CSV |
| `sweep_results_1.csv`, `sweep_results2.csv` | ตัวอย่างผลลัพธ์ CSV |
| `Example Result.txt` | บันทึกตัวอย่าง output จากเทอร์มินัล |
| `Screenshot *.png` | ตัวอย่างหน้าจอรายงาน HTML |

---

## หมายเหตุ

- สคริปต์ออกแบบสำหรับ **Linux** เป็นหลัก (macOS อาจไม่มี `drop_caches` แบบเดียวกัน)  
- การทดสอบบน production path ควรได้รับอนุมัติและมีแผน rollback  
- ขนาดไฟล์ต่อ job ควร **ใหญ่กว่า RAM** ในเคสที่ต้องการหลีกเลี่ยงผลจาก cache ในสถานการณ์ที่ซับซ้อน (สคริปต์มีคำแนะนำในเมนู)

---

## License

โปรเจกต์นี้จัดให้ “ตามสภาพ” เพื่อใช้วัดและเปรียบเทียบ IO ภายในองค์กร — ตรวจสอบนโยบายการใช้งานขององค์กรคุณก่อนนำไปใช้ในระบบจริง
