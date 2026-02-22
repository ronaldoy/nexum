module DirectUploads
  module BlobValidation
    private

    def resolve_blob(raw_signed_id:)
      signed_id = raw_signed_id.to_s.strip
      return nil if signed_id.blank?

      ActiveStorage::Blob.find_signed!(signed_id)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      raise_validation_error!("invalid_blob_signed_id", "blob_signed_id is invalid.")
    end

    def attach_blob!(record:, blob:)
      return if blob.blank?

      record.file.attach(blob)
    end

    def validate_blob_tenant_metadata!(blob:)
      metadata_tenant_id = blob.metadata&.dig("tenant_id").to_s.strip
      if metadata_tenant_id.blank?
        raise_validation_error!("missing_blob_tenant_metadata", "blob metadata tenant is required.")
      end
      return if metadata_tenant_id == @tenant_id.to_s

      raise_validation_error!("blob_tenant_mismatch", "blob metadata tenant does not match request tenant.")
    end

    def validate_blob_actor_party_metadata!(blob:, expected_actor_party_id:)
      return if blob.blank?
      return unless enforce_blob_actor_metadata?(blob)

      metadata_actor_party_id = blob.metadata&.dig("actor_party_id").to_s.strip
      if metadata_actor_party_id.blank?
        raise_validation_error!("missing_blob_actor_party_metadata", "blob metadata actor party is required.")
      end
      return if metadata_actor_party_id == expected_actor_party_id.to_s

      raise_validation_error!("blob_actor_party_mismatch", blob_actor_party_mismatch_message)
    end

    def enforce_blob_actor_metadata?(blob)
      metadata = blob.metadata.is_a?(Hash) ? blob.metadata : {}
      metadata["direct_upload_actor_key"].to_s.strip.present? ||
        metadata["direct_upload_idempotency_key"].to_s.strip.present?
    end

    def blob_actor_party_mismatch_message
      "blob metadata actor party does not match request actor."
    end
  end
end
