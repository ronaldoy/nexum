class HardenAnticipationRequestMutationGate < ActiveRecord::Migration[8.2]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION app_protect_anticipation_requests()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'DELETE not allowed on anticipation_requests';
        END IF;

        IF TG_OP = 'UPDATE' THEN
          IF current_setting('app.allow_anticipation_status_transition', true) <> 'true' THEN
            RAISE EXCEPTION 'UPDATE not allowed on anticipation_requests without status transition gate';
          END IF;

          IF NEW.id IS DISTINCT FROM OLD.id
            OR NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
            OR NEW.receivable_id IS DISTINCT FROM OLD.receivable_id
            OR NEW.receivable_allocation_id IS DISTINCT FROM OLD.receivable_allocation_id
            OR NEW.requester_party_id IS DISTINCT FROM OLD.requester_party_id
            OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
            OR NEW.requested_amount IS DISTINCT FROM OLD.requested_amount
            OR NEW.discount_rate IS DISTINCT FROM OLD.discount_rate
            OR NEW.discount_amount IS DISTINCT FROM OLD.discount_amount
            OR NEW.net_amount IS DISTINCT FROM OLD.net_amount
            OR NEW.channel IS DISTINCT FROM OLD.channel
            OR NEW.requested_at IS DISTINCT FROM OLD.requested_at
            OR NEW.settlement_target_date IS DISTINCT FROM OLD.settlement_target_date
            OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'Only status, funded_at, settled_at, metadata, and updated_at can change on anticipation_requests';
          END IF;

          IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'Status must change when updating anticipation_requests';
          END IF;

          IF NOT (
            (OLD.status = 'REQUESTED' AND NEW.status IN ('APPROVED', 'CANCELLED', 'REJECTED')) OR
            (OLD.status = 'APPROVED' AND NEW.status IN ('FUNDED', 'SETTLED', 'CANCELLED')) OR
            (OLD.status = 'FUNDED' AND NEW.status IN ('SETTLED', 'CANCELLED'))
          ) THEN
            RAISE EXCEPTION 'Invalid anticipation_requests status transition from % to %', OLD.status, NEW.status;
          END IF;

          IF NEW.status = 'FUNDED' AND NEW.funded_at IS NULL THEN
            RAISE EXCEPTION 'funded_at is required when status transitions to FUNDED';
          END IF;

          IF NEW.status = 'SETTLED' AND NEW.settled_at IS NULL THEN
            RAISE EXCEPTION 'settled_at is required when status transitions to SETTLED';
          END IF;

          IF NEW.status <> 'FUNDED' AND NEW.funded_at IS DISTINCT FROM OLD.funded_at THEN
            RAISE EXCEPTION 'funded_at can only change when status transitions to FUNDED';
          END IF;

          IF NEW.status <> 'SETTLED' AND NEW.settled_at IS DISTINCT FROM OLD.settled_at THEN
            RAISE EXCEPTION 'settled_at can only change when status transitions to SETTLED';
          END IF;
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL
  end

  def down
    execute <<~SQL
      CREATE OR REPLACE FUNCTION app_protect_anticipation_requests()
      RETURNS trigger
      LANGUAGE plpgsql
      AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN
          RAISE EXCEPTION 'DELETE not allowed on anticipation_requests';
        END IF;

        IF TG_OP = 'UPDATE' THEN
          IF current_setting('app.allow_anticipation_status_transition', true) = 'true' THEN
            RETURN NEW;
          END IF;
          RAISE EXCEPTION 'UPDATE not allowed on anticipation_requests without status transition gate';
        END IF;

        RETURN NEW;
      END;
      $$;
    SQL
  end
end
