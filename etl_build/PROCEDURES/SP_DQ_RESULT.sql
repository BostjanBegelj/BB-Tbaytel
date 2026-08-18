-- ============================================================
-- Standalone Antfarm DQ result extraction / notification
--
-- Deploy in environment database:
--   DEV_DB.ADM / TEST_DB.ADM / PROD_DB.ADM
--
-- Antfarm source:
--   PLATFORM_DB.ANTFARM.DQ_LOG
--
-- Purpose:
--   * Read a completed run directly from historical DQ_LOG.
--   * JSON mode: return a machine-readable result.
--   * EMAIL mode: send notifications for failed checks and return
--     the same result plus email status.
--
-- Important:
--   * DQ_RULES is intentionally not joined. DQ_LOG is treated as
--     the historical execution snapshot.
--   * Rows with NUM_OF_ERRORS = 0 are read too, so a valid clean
--     run is distinguishable from an invalid RUN_ID.
--   * DQ findings do not turn status into FAILED.
--   * ERROR_ROWS returned to callers are capped by
--     P_MAX_ERROR_ROWS (default 20).
--   * EMAIL mode reports emails_sent / emails_skipped separately.
--     SKIPPED = findings existed but Antfarm had no active
--     recipient, so they reached nobody.
--
-- Session context:
--   ADM.* is schema-qualified only, as everywhere else in this
--   framework. The caller must have the environment database set.
-- ============================================================
use role dev_sysadmin;
use database dev_db;
use schema adm;

CREATE OR REPLACE PROCEDURE ADM.SP_DQ_RESULT(
    P_RUN_ID         VARCHAR,
    P_OUTPUT_TYPE    VARCHAR DEFAULT 'JSON',
    P_MAX_ERROR_ROWS NUMBER  DEFAULT 20
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json
import html
from datetime import datetime, timezone


def parse_value(value):
    if value is None:
        return None

    if isinstance(value, (dict, list, int, float, bool)):
        return value

    try:
        return json.loads(str(value))
    except Exception:
        return value


def to_int(value, default=0):
    try:
        return int(value)
    except Exception:
        return default


def esc(value):
    return html.escape("" if value is None else str(value))


def get_dq_log(session, run_id):

    sql = """
        SELECT
            DQ_LOG_ID,
            RUN_ID,
            PROJECT,
            CALLER,

            DQ_GROUP_ID,
            DQ_GROUP_NAME,

            DQ_RULE_ID,
            DQ_RULE_NAME,
            DQ_CHECK_TYPE,

            DQ_SEVERITY_LEVEL,
            DQ_SEVERITY_NAME,

            SCHEMA_NAME,
            TABLE_NAME,
            COLUMN_NAME,

            NUM_OF_ERRORS,
            ERROR_ROWS,

            DQ_TAG_NAMES,
            SF_QUERY_ID,
            RUN_PARAMETERS,

            CASE
                WHEN IS_ARRAY(
                    TRY_PARSE_JSON(DQ_LOG_MAIL_TO):active
                )
                THEN ARRAY_TO_STRING(
                    TRY_PARSE_JSON(DQ_LOG_MAIL_TO):active,
                    ', '
                )
                ELSE DQ_LOG_MAIL_TO
            END AS MAIL_TO,

            CASE
                WHEN IS_ARRAY(
                    TRY_PARSE_JSON(DQ_LOG_MAIL_CC):active
                )
                THEN ARRAY_TO_STRING(
                    TRY_PARSE_JSON(DQ_LOG_MAIL_CC):active,
                    ', '
                )
                ELSE DQ_LOG_MAIL_CC
            END AS MAIL_CC

        FROM PLATFORM_DB.ANTFARM.DQ_LOG

        WHERE RUN_ID = ?

        ORDER BY
            DQ_GROUP_NAME,
            DQ_RULE_NAME,
            DQ_LOG_ID
    """

    return session.sql(
        sql,
        params=[run_id]
    ).collect()


def limit_error_rows(value, max_rows):

    parsed = parse_value(value)

    if not isinstance(parsed, list):
        return parsed, None, False

    available = len(parsed)
    returned = parsed[:max_rows]
    truncated = available > max_rows

    return returned, available, truncated


def build_result(rows, run_id, output_type, max_error_rows):

    first = rows[0]

    failed = []
    total_errors = 0

    max_severity_level = None
    max_severity_name = None

    dq_groups = []

    for row in rows:

        group_name = row["DQ_GROUP_NAME"]

        if group_name not in dq_groups:
            dq_groups.append(group_name)

        num_errors = to_int(row["NUM_OF_ERRORS"])

        if num_errors <= 0:
            continue

        severity_level = to_int(row["DQ_SEVERITY_LEVEL"])

        total_errors += num_errors

        if (
            max_severity_level is None
            or severity_level > max_severity_level
        ):
            max_severity_level = severity_level
            max_severity_name = row["DQ_SEVERITY_NAME"]

        error_rows, error_rows_available, error_rows_truncated = (
            limit_error_rows(
                row["ERROR_ROWS"],
                max_error_rows
            )
        )

        failed.append({
            "dq_log_id":
                row["DQ_LOG_ID"],

            "dq_group_id":
                row["DQ_GROUP_ID"],

            "dq_group_name":
                row["DQ_GROUP_NAME"],

            "dq_rule_id":
                row["DQ_RULE_ID"],

            "dq_rule_name":
                row["DQ_RULE_NAME"],

            "check_type":
                row["DQ_CHECK_TYPE"],

            "severity_level":
                severity_level,

            "severity_name":
                row["DQ_SEVERITY_NAME"],

            "schema_name":
                row["SCHEMA_NAME"],

            "table_name":
                row["TABLE_NAME"],

            "column_name":
                row["COLUMN_NAME"],

            "num_of_errors":
                num_errors,

            "error_rows":
                error_rows,

            "error_rows_available":
                error_rows_available,

            "error_rows_truncated":
                error_rows_truncated,

            "tag_names":
                parse_value(row["DQ_TAG_NAMES"]),

            "sf_query_id":
                row["SF_QUERY_ID"]
        })


    return {
        "status":
            "SUCCESS",

        "run_id":
            run_id,

        "output_type":
            output_type,

        "project":
            first["PROJECT"],

        "caller":
            first["CALLER"],

        "dq_group_name":
            dq_groups[0] if len(dq_groups) == 1 else None,

        "dq_groups":
            dq_groups,

        "run_parameters":
            parse_value(first["RUN_PARAMETERS"]),

        "has_issues":
            len(failed) > 0,

        "total_checks":
            len(rows),

        "failed_checks":
            len(failed),

        "total_errors":
            total_errors,

        "max_severity_level":
            max_severity_level,

        "max_severity_name":
            max_severity_name,

        "max_error_rows":
            max_error_rows,

        "results":
            failed
    }


def render_error_rows(error_rows, was_truncated):

    rows = error_rows

    if not isinstance(rows, list) or not rows:
        return ""

    if not isinstance(rows[0], dict):
        suffix = (
            "<div style=\"margin-top:5px;color:#6b7280;font-size:10px;\">"
            "Error rows were truncated for output.</div>"
            if was_truncated
            else ""
        )

        return (
            "<pre style=\"white-space:pre-wrap;\">"
            + esc(json.dumps(rows, indent=2))
            + "</pre>"
            + suffix
        )

    headers = list(rows[0].keys())

    header_html = "".join(
        f"""
        <th bgcolor="#f1f5f9"
            style="padding:7px 8px;border:1px solid #d1d5db;
                   background-color:#f1f5f9;text-align:left;
                   font-family:Arial,Helvetica,sans-serif;font-size:11px;">
            {esc(h)}
        </th>
        """
        for h in headers
    )

    rows_html = ""

    for item in rows:

        cells = "".join(
            f"""
            <td style="padding:7px 8px;border:1px solid #d1d5db;
                       vertical-align:top;font-family:Arial,Helvetica,sans-serif;
                       font-size:11px;">
                {esc(item.get(h))}
            </td>
            """
            for h in headers
        )

        rows_html += f"<tr>{cells}</tr>"

    note = (
        "Returned error rows were truncated."
        if was_truncated
        else f"Showing {len(rows)} error row(s)."
    )

    return f"""
        <div style="overflow-x:auto;margin-top:10px;">
            <table cellpadding="0" cellspacing="0" border="0"
                   style="border-collapse:collapse;width:100%;">
                <tr>{header_html}</tr>
                {rows_html}
            </table>
        </div>
        <div style="margin-top:5px;color:#6b7280;font-size:10px;">
            {esc(note)}
        </div>
    """


def build_email(group_name, checks, run_id, env):

    max_check = max(
        checks,
        key=lambda x: to_int(x["severity_level"])
    )

    total_errors = sum(
        to_int(x["num_of_errors"])
        for x in checks
    )

    sections = ""

    for check in checks:

        object_name = ".".join(
            str(x)
            for x in [
                check.get("schema_name"),
                check.get("table_name"),
                check.get("column_name")
            ]
            if x not in (None, "")
        )

        sections += f"""
        <table width="100%" cellpadding="0" cellspacing="0" border="0"
               style="margin-top:16px;border:1px solid #e5e7eb;">
            <tr>
                <td bgcolor="#f8fafc"
                    style="padding:10px 12px;background-color:#f8fafc;
                           font-family:Arial,Helvetica,sans-serif;">
                    <div style="font-size:13px;font-weight:bold;color:#111827;">
                        {esc(check["dq_rule_name"])}
                    </div>
                    <div style="margin-top:4px;font-size:11px;color:#6b7280;">
                        Severity: {esc(check["severity_name"])}
                        ({esc(check["severity_level"])})
                        &nbsp;|&nbsp;
                        Check: {esc(check["check_type"])}
                        &nbsp;|&nbsp;
                        Errors: {esc(check["num_of_errors"])}
                    </div>
                </td>
            </tr>
            <tr>
                <td style="padding:12px;font-family:Arial,Helvetica,sans-serif;
                           font-size:11px;color:#374151;">
                    <div><b>Object:</b> {esc(object_name or "N/A")}</div>
                    <div style="margin-top:3px;">
                        <b>Snowflake Query ID:</b>
                        {esc(check["sf_query_id"] or "N/A")}
                    </div>

                    {render_error_rows(
                        check["error_rows"],
                        bool(check["error_rows_truncated"])
                    )}

                </td>
            </tr>
        </table>
        """

    return f"""
    <!doctype html>
    <html>
    <body bgcolor="#f1f5f9"
          style="margin:0;padding:0;background-color:#f1f5f9;">

    <table width="100%" cellpadding="0" cellspacing="0" border="0"
           bgcolor="#f1f5f9"
           style="background-color:#f1f5f9;">
        <tr>
            <td align="center" style="padding:20px 10px;">

                <table width="800" cellpadding="0" cellspacing="0" border="0"
                       bgcolor="#ffffff"
                       style="width:100%;max-width:800px;background-color:#ffffff;
                              border:1px solid #dbe2ea;">

                    <tr>
                        <td bgcolor="#b45309"
                            style="padding:18px 20px;background-color:#b45309;
                                   font-family:Arial,Helvetica,sans-serif;color:#ffffff;">
                            <div style="font-size:19px;font-weight:bold;">
                                Data Quality Alert: {esc(group_name)}
                            </div>
                            <div style="margin-top:5px;font-size:12px;">
                                {esc(env)}
                                &nbsp;|&nbsp;
                                Severity: {esc(max_check["severity_name"])}
                            </div>
                        </td>
                    </tr>

                    <tr>
                        <td style="padding:18px 20px;
                                   font-family:Arial,Helvetica,sans-serif;">

                            <table cellpadding="0" cellspacing="0" border="0"
                                   style="font-size:12px;color:#374151;">
                                <tr>
                                    <td style="padding:3px 12px 3px 0;">
                                        <b>Run ID</b>
                                    </td>
                                    <td>{esc(run_id)}</td>
                                </tr>
                                <tr>
                                    <td style="padding:3px 12px 3px 0;">
                                        <b>Failed checks</b>
                                    </td>
                                    <td>{len(checks)}</td>
                                </tr>
                                <tr>
                                    <td style="padding:3px 12px 3px 0;">
                                        <b>Total errors</b>
                                    </td>
                                    <td>{total_errors}</td>
                                </tr>
                            </table>

                            {sections}

                        </td>
                    </tr>

                    <tr>
                        <td bgcolor="#f8fafc"
                            style="padding:12px 20px;background-color:#f8fafc;
                                   border-top:1px solid #e5e7eb;
                                   font-family:Arial,Helvetica,sans-serif;
                                   font-size:10px;color:#6b7280;">
                            Automated Data Quality notification.
                            Generated:
                            {datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")} UTC
                        </td>
                    </tr>

                </table>

            </td>
        </tr>
    </table>

    </body>
    </html>
    """


def send_emails(session, rows, result, run_id):

    env = session.sql(
        "SELECT CURRENT_DATABASE()"
    ).collect()[0][0]

    failed_by_log_id = {
        str(check["dq_log_id"]): check
        for check in result["results"]
    }

    batches = {}

    for row in rows:

        log_id = str(row["DQ_LOG_ID"])

        if log_id not in failed_by_log_id:
            continue

        group_name = row["DQ_GROUP_NAME"]
        to_addr = (row["MAIL_TO"] or "").strip()
        cc_addr = (row["MAIL_CC"] or "").strip()

        key = (
            group_name,
            to_addr,
            cc_addr
        )

        if key not in batches:
            batches[key] = []

        batches[key].append(
            failed_by_log_id[log_id]
        )


    email_results = []
    emails_sent = 0

    for (group_name, to_addr, cc_addr), checks in batches.items():

        if not to_addr:

            email_results.append({
                "group":
                    group_name,

                "status":
                    "SKIPPED",

                "reason":
                    "No active email recipient configured"
            })

            continue


        max_check = max(
            checks,
            key=lambda x: to_int(x["severity_level"])
        )

        subject = (
            f"DQ {max_check['severity_name']} | "
            f"{env} | "
            f"Group: {group_name} | "
            f"RUN {run_id}"
        )

        body = build_email(
            group_name,
            checks,
            run_id,
            env
        )


        try:

            response = session.sql(
                """
                CALL ADM.SP_SEND_NOTIFICATION(
                    ?, ?, ?, ?
                )
                """,
                params=[
                    subject,
                    body,
                    to_addr,
                    cc_addr
                ]
            ).collect()

            raw = response[0][0] if response else None
            send_result = parse_value(raw)

            if isinstance(send_result, dict):
                send_status = str(
                    send_result.get("status", "UNKNOWN")
                ).upper()
            else:
                send_status = "UNKNOWN"

            if send_status == "SUCCESS":

                emails_sent += 1

                email_results.append({
                    "group":
                        group_name,

                    "status":
                        "SENT",

                    "to":
                        to_addr,

                    "cc":
                        cc_addr,

                    "failed_checks":
                        len(checks)
                })

            else:

                email_results.append({
                    "group":
                        group_name,

                    "status":
                        "FAILED",

                    "to":
                        to_addr,

                    "cc":
                        cc_addr,

                    "send_status":
                        send_status,

                    "send_result":
                        send_result
                })


        except Exception as exc:

            email_results.append({
                "group":
                    group_name,

                "status":
                    "FAILED",

                "to":
                    to_addr,

                "cc":
                    cc_addr,

                "error":
                    str(exc)
            })


    return emails_sent, email_results


def derive_email_status(email_results):

    if not email_results:
        return "NOT_REQUIRED"

    statuses = [
        str(x.get("status", "")).upper()
        for x in email_results
    ]

    sent_count = sum(1 for x in statuses if x == "SENT")
    failed_count = sum(1 for x in statuses if x == "FAILED")
    skipped_count = sum(1 for x in statuses if x == "SKIPPED")

    if failed_count > 0 and sent_count > 0:
        return "PARTIAL"

    if failed_count > 0:
        return "FAILED"

    if sent_count > 0:
        return "SUCCESS"

    if skipped_count > 0:
        return "SKIPPED"

    return "FAILED"


def main(
    session,
    p_run_id: str,
    p_output_type: str,
    p_max_error_rows: int
):

    if p_run_id is None or not str(p_run_id).strip():

        return {
            "status":
                "FAILED",

            "message":
                "P_RUN_ID is required"
        }


    output_type = (
        p_output_type or "JSON"
    ).strip().upper()


    if output_type not in ("JSON", "EMAIL"):

        return {
            "status":
                "FAILED",

            "run_id":
                p_run_id,

            "message":
                "P_OUTPUT_TYPE must be JSON or EMAIL"
        }


    max_error_rows = to_int(
        p_max_error_rows,
        20
    )

    if max_error_rows <= 0 or max_error_rows > 1000:

        return {
            "status":
                "FAILED",

            "run_id":
                p_run_id,

            "message":
                "P_MAX_ERROR_ROWS must be between 1 and 1000"
        }


    rows = get_dq_log(
        session,
        p_run_id
    )


    if not rows:

        return {
            "status":
                "FAILED",

            "run_id":
                p_run_id,

            "output_type":
                output_type,

            "message":
                "RUN_ID not found in PLATFORM_DB.ANTFARM.DQ_LOG"
        }


    result = build_result(
        rows,
        p_run_id,
        output_type,
        max_error_rows
    )


    if output_type == "JSON":
        return result


    if not result["has_issues"]:

        result["emails_sent"] = 0
        result["emails_skipped"] = 0
        result["email_status"] = "NOT_REQUIRED"
        result["email_results"] = []

        return result


    emails_sent, email_results = send_emails(
        session,
        rows,
        result,
        p_run_id
    )

    email_status = derive_email_status(
        email_results
    )

    # Groups whose findings reached nobody because Antfarm had no
    # active recipient. Counted explicitly so a mixed run cannot
    # report a clean SUCCESS while some findings went undelivered.
    emails_skipped = sum(
        1
        for x in email_results
        if str(x.get("status", "")).upper() == "SKIPPED"
    )

    result["emails_sent"] = emails_sent
    result["emails_skipped"] = emails_skipped
    result["email_status"] = email_status
    result["email_results"] = email_results

    # An actual email transport failure is a technical failure.
    # SKIPPED is a configuration gap, not a transport failure, so it
    # does not fail the run - but it is surfaced.
    if email_status in ("FAILED", "PARTIAL"):
        result["status"] = "FAILED"
        result["message"] = "One or more DQ notification emails failed"
    elif emails_skipped > 0:
        result["message"] = (
            f"{emails_skipped} DQ group(s) with findings have no "
            f"active Antfarm email recipient configured"
        )

    return result
$$;


-- Examples:
--
-- CALL ADM.SP_DQ_RESULT('<run_id>', 'JSON');
--
-- CALL ADM.SP_DQ_RESULT('<run_id>', 'EMAIL');
--
-- Override returned error-row cap:
-- CALL ADM.SP_DQ_RESULT('<run_id>', 'JSON', 50);
