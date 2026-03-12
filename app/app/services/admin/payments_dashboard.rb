module Admin
  class PaymentsDashboard
    STATUS_FILTERS = {
      "pending" => "PENDING",
      "processing" => "PROCESSING",
      "sent" => "SENT",
      "failed" => "FAILED"
    }.freeze

    def initialize(tenant:)
      @tenant = tenant
    end

    def call(page: 1, per_page: 20, status: nil)
      paginated = paginated_payout_rows(page:, per_page:, status:)
      payment_instruction_snapshot = payment_instruction_tracker.snapshot(tenant_id: tenant.id)

      {
        generated_at: Time.current,
        headline_cards: headline_cards,
        payout_rows: paginated.fetch(:rows),
        payout_pagination: paginated.fetch(:pagination),
        batch_rows: batch_rows(limit: 12),
        failure_rows: failure_rows(limit: 8),
        payment_instruction_monitor_cards: payment_instruction_monitor_cards(payment_instruction_snapshot),
        payment_instruction_event_rows: payment_instruction_tracker.problematic_rows(tenant_id: tenant.id, limit: 10),
        active_status: status
      }
    end

    def paginated_payout_rows(page:, per_page:, status:)
      scope = filtered_payout_scope(status)
      total_count = scope.count
      per_page_value = [ per_page.to_i, 1 ].max
      total_pages = total_count.zero? ? 1 : (total_count.to_f / per_page_value).ceil
      current_page = [ [ page.to_i, 1 ].max, total_pages ].min
      offset = (current_page - 1) * per_page_value
      rows = scope.offset(offset).limit(per_page_value).map { |payout| payout_row(payout) }
      from = total_count.zero? ? 0 : offset + 1
      to = total_count.zero? ? 0 : offset + rows.length

      {
        rows: rows,
        pagination: {
          page: current_page,
          per_page: per_page_value,
          total_count: total_count,
          total_pages: total_pages,
          from: from,
          to: to,
          prev_page: current_page > 1 ? current_page - 1 : nil,
          next_page: current_page < total_pages ? current_page + 1 : nil
        }
      }
    end

    def batch_rows(limit: 10)
      EscrowPayoutBatch
        .where(tenant_id: tenant.id)
        .includes(:escrow_payouts)
        .recent_first
        .limit(limit)
        .map do |batch|
          {
            batch: batch,
            payouts_count: batch.escrow_payouts.size,
            pending_capacity: [ batch.risk_limit_amount.to_d - batch.dispatched_amount.to_d, 0.to_d ].max
          }
        end
    end

    def failure_rows(limit: 8)
      EscrowPayout
        .where(tenant_id: tenant.id, status: "FAILED")
        .includes(:party, :escrow_payout_batch)
        .order(processed_at: :desc, updated_at: :desc)
        .limit(limit)
        .map { |payout| payout_row(payout) }
    end

    private

    attr_reader :tenant

    def headline_cards
      scope = EscrowPayout.where(tenant_id: tenant.id)
      pending_scope = scope.where(status: "PENDING")
      processing_scope = scope.where(status: "PROCESSING")
      confirmed_scope = scope.where(status: "SENT")
      failed_scope = scope.where(status: "FAILED")
      batches_scope = EscrowPayoutBatch.where(tenant_id: tenant.id)

      [
        {
          label: "Fila pendente",
          value: pending_scope.sum(:amount),
          footnote: "#{pending_scope.count} pagamentos aguardando saldo na conta operacional ou envio",
          kind: :money
        },
        {
          label: "PIX processando",
          value: processing_scope.count,
          footnote: "#{processing_scope.sum(:amount).to_d.to_s("F")} BRL em trânsito"
        },
        {
          label: "Confirmados hoje",
          value: confirmed_scope.where(confirmed_at: Time.current.beginning_of_day..Time.current.end_of_day).count,
          footnote: "#{confirmed_scope.where(confirmed_at: Time.current.beginning_of_day..Time.current.end_of_day).sum(:amount).to_d.to_s("F")} BRL liquidados"
        },
        {
          label: "Falhas abertas",
          value: failed_scope.count,
          footnote: "#{failed_scope.sum(:amount).to_d.to_s("F")} BRL exigem reprocessamento"
        },
        {
          label: "Taxa Stark",
          value: scope.sum(:provider_fee_amount),
          footnote: "Soma das taxas devolvidas pelo provedor",
          kind: :money
        },
        {
          label: "Lotes abertos",
          value: batches_scope.where(status: "OPEN").count,
          footnote: "#{batches_scope.count} lotes registrados no histórico"
        }
      ]
    end

    def filtered_payout_scope(status)
      scope = EscrowPayout
        .where(tenant_id: tenant.id)
        .includes(:party, { escrow_account: :party }, :escrow_payout_batch, receivable_payment_settlement: :receivable)
        .order(requested_at: :desc, created_at: :desc)

      mapped_status = STATUS_FILTERS[status.to_s]
      mapped_status.present? ? scope.where(status: mapped_status) : scope
    end

    def payment_instruction_monitor_cards(snapshot)
      [
        {
          label: "Backlog vencido",
          value: snapshot.fetch(:stale_count),
          footnote: payment_instruction_oldest_age_label(snapshot)
        },
        {
          label: "Retries agendados",
          value: snapshot.fetch(:retry_scheduled_count),
          footnote: "Eventos aguardando nova tentativa automática do outbox"
        },
        {
          label: "Dead letters",
          value: snapshot.fetch(:dead_letter_count),
          footnote: "Eventos que exigem replay manual da operação"
        },
        {
          label: "Pendentes recentes",
          value: snapshot.fetch(:pending_count),
          footnote: "Eventos ainda dentro da janela operacional normal"
        }
      ]
    end

    def payment_instruction_oldest_age_label(snapshot)
      oldest_stale_created_at = snapshot.fetch(:oldest_stale_created_at)
      return "Nenhum evento de instrução PIX fora do SLA" if oldest_stale_created_at.blank?

      "Evento mais antigo há #{ActionController::Base.helpers.distance_of_time_in_words(oldest_stale_created_at, Time.current)}"
    end

    def payment_instruction_tracker
      @payment_instruction_tracker ||= Outbox::PaymentInstructionEventTracker.new
    end

    def payout_row(payout)
      settlement = payout.receivable_payment_settlement
      receivable = settlement&.receivable

      {
        payout: payout,
        party: payout.party,
        source_party: payout.escrow_account&.party,
        batch: payout.escrow_payout_batch,
        receivable_reference: receivable&.external_reference || settlement&.id&.first(8),
        confirmed: payout.confirmed?,
        provider_status: payout.provider_status.to_s.presence || payout.status.downcase,
        payout_model: settlement&.payout_model,
        retained_amount: settlement&.retained_amount.to_d || 0.to_d
      }
    end
  end
end
