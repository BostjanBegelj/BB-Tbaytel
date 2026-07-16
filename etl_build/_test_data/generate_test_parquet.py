"""
Generate deterministic test Parquet files for technically exercising the Tbaytel
ETL procedures against INT_STAGE_AZURE (internal stand-in for the Azure Blob stage).

Design goals
  * Type coverage: int64/int32, string, bool, date, timestamp, decimal, and NULLs
    -> with FILE_FORMAT_PARQUET (use_logical_type=true) these surface in Snowflake
       as NUMBER/VARCHAR/BOOLEAN/DATE/TIMESTAMP_NTZ/NUMBER(p,s).
  * Change patterns across 3 load dates so you can test full-snapshot CDC:
      CUSTOMER / SERVICE_PLAN = full snapshot each date (update + insert + delete)
      USAGE_DAILY            = per-day fact rows (append pattern)

Layout written (mirrors an Azure Blob container; source system = BSS_ORA):
  _test_data/BSS_ORA/<TABLE>/load_date=YYYY-MM-DD/<TABLE>_YYYYMMDD.parquet

Reproducible: same output every run. Requires pyarrow.
    python etl_build/_test_data/generate_test_parquet.py
"""
import os
import datetime as dt
import pyarrow as pa
import pyarrow.parquet as pq

BASE = os.path.join(os.path.dirname(__file__), "BSS_ORA")
SOURCE = "BSS_ORA"
DATES = ["2026-07-01", "2026-07-02", "2026-07-03"]

DEC_2 = pa.decimal128(10, 2)
DEC_3 = pa.decimal128(12, 3)


def ts(s):
    return dt.datetime.strptime(s, "%Y-%m-%d %H:%M:%S")


def d(s):
    return dt.date.fromisoformat(s)


def write(table_name, load_date, arrays, schema):
    tbl = pa.table(arrays, schema=schema)
    out_dir = os.path.join(BASE, table_name, f"load_date={load_date}")
    os.makedirs(out_dir, exist_ok=True)
    fname = f"{table_name}_{load_date.replace('-', '')}.parquet"
    pq.write_table(tbl, os.path.join(out_dir, fname))
    print(f"  {table_name} {load_date}: {tbl.num_rows} rows -> {fname}")


# ---------------------------------------------------------------- CUSTOMER (dim)
CUST_SCHEMA = pa.schema([
    ("CUSTOMER_ID", pa.int64()),
    ("FIRST_NAME", pa.string()),
    ("LAST_NAME", pa.string()),
    ("EMAIL", pa.string()),            # nullable
    ("CITY", pa.string()),
    ("PROVINCE", pa.string()),
    ("SEGMENT", pa.string()),
    ("CREDIT_LIMIT", DEC_2),
    ("IS_ACTIVE", pa.bool_()),
    ("CREATED_TS", pa.timestamp("us")),
    ("UPDATED_TS", pa.timestamp("us")),
])

# base rows keyed by CUSTOMER_ID; value = dict of attrs
def cust_row(cid, fn, ln, email, city, prov, seg, credit, active, created, updated):
    return dict(CUSTOMER_ID=cid, FIRST_NAME=fn, LAST_NAME=ln, EMAIL=email,
                CITY=city, PROVINCE=prov, SEGMENT=seg, CREDIT_LIMIT=D(credit),
                IS_ACTIVE=active, CREATED_TS=ts(created), UPDATED_TS=ts(updated))

from decimal import Decimal as D

CUST = {
    "2026-07-01": [
        cust_row(1001, "Alice", "Nguyen", "alice.nguyen@example.ca", "Thunder Bay", "ON", "CONSUMER", "500.00", True,  "2025-01-10 09:00:00", "2025-01-10 09:00:00"),
        cust_row(1002, "Bruno", "Kowalski", None,                     "Kenora",     "ON", "CONSUMER", "750.00", True,  "2025-02-14 11:30:00", "2025-02-14 11:30:00"),
        cust_row(1003, "Chen",  "Li",      "chen.li@example.ca",      "Dryden",     "ON", "BUSINESS", "2500.00", True, "2025-03-01 08:15:00", "2025-03-01 08:15:00"),
        cust_row(1004, "Dana",  "Osei",    "dana.osei@example.ca",    "Fort Frances","ON","CONSUMER", "500.00", True,  "2025-04-20 14:45:00", "2025-04-20 14:45:00"),
        cust_row(1005, "Evan",  "Roy",     "evan.roy@example.ca",     "Marathon",   "ON", "CONSUMER", "0.00",   False, "2025-05-05 16:00:00", "2025-05-05 16:00:00"),
    ],
    # 1002 updated (moved city + updated_ts), 1006 inserted
    "2026-07-02": [
        cust_row(1001, "Alice", "Nguyen", "alice.nguyen@example.ca", "Thunder Bay", "ON", "CONSUMER", "500.00", True,  "2025-01-10 09:00:00", "2025-01-10 09:00:00"),
        cust_row(1002, "Bruno", "Kowalski", "bruno.k@example.ca",     "Thunder Bay","ON", "CONSUMER", "750.00", True,  "2025-02-14 11:30:00", "2026-07-02 07:10:00"),
        cust_row(1003, "Chen",  "Li",      "chen.li@example.ca",      "Dryden",     "ON", "BUSINESS", "2500.00", True, "2025-03-01 08:15:00", "2025-03-01 08:15:00"),
        cust_row(1004, "Dana",  "Osei",    "dana.osei@example.ca",    "Fort Frances","ON","CONSUMER", "500.00", True,  "2025-04-20 14:45:00", "2025-04-20 14:45:00"),
        cust_row(1005, "Evan",  "Roy",     "evan.roy@example.ca",     "Marathon",   "ON", "CONSUMER", "0.00",   False, "2025-05-05 16:00:00", "2025-05-05 16:00:00"),
        cust_row(1006, "Fiona", "Park",    "fiona.park@example.ca",   "Sioux Lookout","ON","BUSINESS","3000.00", True, "2026-07-02 10:00:00", "2026-07-02 10:00:00"),
    ],
    # 1002 deleted (absent), 1004 updated (credit raised)
    "2026-07-03": [
        cust_row(1001, "Alice", "Nguyen", "alice.nguyen@example.ca", "Thunder Bay", "ON", "CONSUMER", "500.00", True,  "2025-01-10 09:00:00", "2025-01-10 09:00:00"),
        cust_row(1003, "Chen",  "Li",      "chen.li@example.ca",      "Dryden",     "ON", "BUSINESS", "2500.00", True, "2025-03-01 08:15:00", "2025-03-01 08:15:00"),
        cust_row(1004, "Dana",  "Osei",    "dana.osei@example.ca",    "Fort Frances","ON","CONSUMER", "1500.00", True, "2025-04-20 14:45:00", "2026-07-03 06:30:00"),
        cust_row(1005, "Evan",  "Roy",     "evan.roy@example.ca",     "Marathon",   "ON", "CONSUMER", "0.00",   False, "2025-05-05 16:00:00", "2025-05-05 16:00:00"),
        cust_row(1006, "Fiona", "Park",    "fiona.park@example.ca",   "Sioux Lookout","ON","BUSINESS","3000.00", True, "2026-07-02 10:00:00", "2026-07-02 10:00:00"),
    ],
}

# ------------------------------------------------------------ SERVICE_PLAN (dim)
PLAN_SCHEMA = pa.schema([
    ("PLAN_ID", pa.int64()),
    ("PLAN_NAME", pa.string()),
    ("MONTHLY_PRICE", pa.decimal128(8, 2)),
    ("DATA_GB", pa.int32()),           # nullable (unlimited -> NULL)
    ("VOICE_UNLIMITED", pa.bool_()),
    ("EFFECTIVE_DATE", pa.date32()),
])

def plan_row(pid, name, price, data_gb, unlimited, eff):
    return dict(PLAN_ID=pid, PLAN_NAME=name, MONTHLY_PRICE=D(price),
                DATA_GB=data_gb, VOICE_UNLIMITED=unlimited, EFFECTIVE_DATE=d(eff))

PLAN = {
    "2026-07-01": [
        plan_row(1, "Talk 100",     "25.00", 1,    False, "2025-01-01"),
        plan_row(2, "Smart 5GB",    "45.00", 5,    True,  "2025-01-01"),
        plan_row(3, "Data Max",     "70.00", None, True,  "2025-01-01"),   # NULL data_gb
        plan_row(4, "Business Pro", "120.00", 50,  True,  "2025-01-01"),
    ],
    # plan 2 price change
    "2026-07-02": [
        plan_row(1, "Talk 100",     "25.00", 1,    False, "2025-01-01"),
        plan_row(2, "Smart 5GB",    "49.99", 5,    True,  "2026-07-02"),
        plan_row(3, "Data Max",     "70.00", None, True,  "2025-01-01"),
        plan_row(4, "Business Pro", "120.00", 50,  True,  "2025-01-01"),
    ],
    # plan 5 inserted
    "2026-07-03": [
        plan_row(1, "Talk 100",     "25.00", 1,    False, "2025-01-01"),
        plan_row(2, "Smart 5GB",    "49.99", 5,    True,  "2026-07-02"),
        plan_row(3, "Data Max",     "70.00", None, True,  "2025-01-01"),
        plan_row(4, "Business Pro", "120.00", 50,  True,  "2025-01-01"),
        plan_row(5, "Student 10GB", "35.00", 10,   False, "2026-07-03"),
    ],
}

# ------------------------------------------------------------- USAGE_DAILY (fact)
USAGE_SCHEMA = pa.schema([
    ("USAGE_ID", pa.int64()),
    ("CUSTOMER_ID", pa.int64()),
    ("PLAN_ID", pa.int64()),
    ("USAGE_DATE", pa.date32()),
    ("VOICE_MINUTES", pa.int32()),
    ("DATA_MB", pa.decimal128(12, 3)),   # nullable
    ("SMS_COUNT", pa.int32()),
    ("CHARGE_AMT", pa.decimal128(10, 2)),
    ("ROAMING_FLAG", pa.bool_()),
    ("EVENT_TS", pa.timestamp("us")),
])

def build_usage(load_date, start_id):
    """4 usage rows per customer-ish, deterministic, for the given day."""
    rows = []
    combos = [(1001, 2), (1002, 1), (1003, 4), (1004, 2), (1005, 3), (1006, 4)]
    uid = start_id
    for i, (cid, pid) in enumerate(combos):
        minutes = 10 + (i * 7) + (start_id % 5)
        data_mb = None if i == 2 else D(f"{100 + i*33}.500")     # one NULL data_mb
        sms = 0 if i == 4 else (3 + i)
        charge = D(f"{(i + 1) * 1.25:.2f}")
        roaming = (i % 3 == 0)
        rows.append(dict(
            USAGE_ID=uid, CUSTOMER_ID=cid, PLAN_ID=pid, USAGE_DATE=d(load_date),
            VOICE_MINUTES=minutes, DATA_MB=data_mb, SMS_COUNT=sms,
            CHARGE_AMT=charge, ROAMING_FLAG=roaming,
            EVENT_TS=ts(f"{load_date} {8 + i}:15:00"),
        ))
        uid += 1
    return rows

USAGE = {dtstr: build_usage(dtstr, 5000 + n * 100) for n, dtstr in enumerate(DATES)}


def rows_to_arrays(rows, schema):
    return {f.name: [r[f.name] for r in rows] for f in schema}


def main():
    specs = [
        ("CUSTOMER", CUST, CUST_SCHEMA),
        ("SERVICE_PLAN", PLAN, PLAN_SCHEMA),
        ("USAGE_DAILY", USAGE, USAGE_SCHEMA),
    ]
    print(f"Writing test Parquet under {BASE} (source={SOURCE})")
    for name, data, schema in specs:
        for load_date in DATES:
            write(name, load_date, rows_to_arrays(data[load_date], schema), schema)
    print("Done.")


if __name__ == "__main__":
    main()
