
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    fee_due NUMERIC(10,2) NOT NULL
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount NUMERIC(10,2) NOT NULL,
    paid_on DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount NUMERIC(10,2) NOT NULL,
    logged_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INTEGER NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

INSERT INTO students (student_number, full_name, fee_due)
VALUES
    ('ST001', 'John Banda', 5000.00),
    ('ST002', 'Mary Phiri', 7000.00),
    ('ST003', 'Peter Zulu', 6000.00);

CREATE OR REPLACE FUNCTION fn_fee_balance(
    p_student_id INTEGER
)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee NUMERIC(10,2);
    v_paid NUMERIC(10,2);
BEGIN
    SELECT fee_due
    INTO v_fee
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student';
    END IF;

    SELECT COALESCE(SUM(amount), 0)
    INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;

CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount NUMERIC,
    p_paid_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(10,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive';
    END IF;

    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date is required';
    END IF;

    SELECT fee_due
    INTO v_balance
    FROM students
    WHERE student_id = p_student_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student';
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment exceeds outstanding balance';
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

CALL pr_receive_payment(1, 1000.00, CURRENT_DATE);
CALL pr_receive_payment(1, 500.00, CURRENT_DATE);
CALL pr_receive_payment(1, 750.00, CURRENT_DATE);

CALL pr_receive_payment(2, 2000.00, CURRENT_DATE);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE);
CALL pr_receive_payment(2, 500.00, CURRENT_DATE);

CREATE OR REPLACE FUNCTION fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (
        payment_id,
        student_id,
        amount,
        logged_at
    )
    VALUES (
        NEW.payment_id,
        NEW.student_id,
        NEW.amount,
        CURRENT_TIMESTAMP
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_payment_audit();

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    student_number,
    full_name,
    fn_fee_balance(student_id) AS outstanding_balance
FROM students
WHERE fn_fee_balance(student_id) > 0;

SELECT * FROM v_fee_balances;


CREATE INDEX idx_payments_student_date
ON payments (student_id, paid_on);

EXPLAIN
SELECT *
FROM payments
WHERE student_id = 1
AND paid_on BETWEEN DATE '2026-11-01'
                AND DATE '2026-11-30';


CREATE OR REPLACE PROCEDURE pr_refresh_collections(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_collections (
        collection_date,
        payment_count,
        total_amount
    )
    SELECT
        p_day,
        COUNT(*)::INTEGER,
        COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day

    ON CONFLICT (collection_date)
    DO UPDATE SET
        payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh-daily-collections',
    '0 1 * * *',
    $$CALL pr_refresh_collections(CURRENT_DATE - 1);$$
);
