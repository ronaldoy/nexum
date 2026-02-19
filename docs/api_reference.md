# API Reference

Generated at: 2026-02-19T17:57:38-03:00
Source contract: `docs/openapi/v1.yaml`

## Authentication

- Partner endpoints use Bearer token authentication.
- Mutating endpoints require `Idempotency-Key`.
- All monetary/rate fields must be sent as strings.

## Endpoints

| Method | Path | Operation ID | Summary | Idempotency | Responses |
| --- | --- | --- | --- | --- | --- |
| `POST` | `/api/v1/anticipation_requests` | `createAnticipationRequest` | Create anticipation request | Yes | 201, 400, 401, 403, 409, 422 |
| `POST` | `/api/v1/anticipation_requests/{id}/confirm` | `confirmAnticipation` | Confirm anticipation by challenge codes | Yes | 200, 400, 401, 403, 404, 409, 422 |
| `POST` | `/api/v1/anticipation_requests/{id}/issue_challenges` | `issueAnticipationChallenges` | Issue email and WhatsApp confirmation challenges | Yes | 200, 400, 401, 403, 404, 409, 422 |
| `GET` | `/api/v1/hospital_organizations` | `listHospitalOrganizations` | List hospital organizations and managed hospitals | No | 200, 401, 403 |
| `POST` | `/api/v1/kyc_profiles` | `createKycProfile` | Create KYC profile | Yes | 201, 400, 401, 403, 409, 422 |
| `GET` | `/api/v1/kyc_profiles/{id}` | `getKycProfile` | Fetch KYC profile | No | 200, 401, 403, 404 |
| `POST` | `/api/v1/kyc_profiles/{id}/submit_document` | `submitKycDocument` | Submit KYC document metadata | Yes | 200, 400, 401, 403, 404, 409, 422 |
| `GET` | `/api/v1/receivables` | `listReceivables` | List receivables | No | 200, 401, 403 |
| `GET` | `/api/v1/receivables/{id}` | `getReceivable` | Fetch receivable by id | No | 200, 401, 403, 404 |
| `POST` | `/api/v1/receivables/{id}/attach_document` | `attachReceivableDocument` | Attach signed document metadata to receivable | Yes | 200, 201, 400, 401, 403, 404, 409, 422 |
| `GET` | `/api/v1/receivables/{id}/history` | `getReceivableHistory` | Fetch receivable timeline | No | 200, 401, 403, 404 |
| `POST` | `/api/v1/receivables/{id}/settle_payment` | `settleReceivablePayment` | Settle receivable payment | Yes | 200, 400, 401, 403, 404, 409, 422 |
| `GET` | `/health` | `getHealth` | Liveness check | No | 200 |
| `GET` | `/ready` | `getReady` | Readiness check | No | 200, 503 |

## Schemas

- `AttachDocumentRequest`
- `ErrorEnvelope`
- `HealthResponse`
- `HistoryItem`
- `MoneyString`
- `PartyReference`
- `ReadyResponse`
- `Receivable`
- `ReceivableProvenance`
- `SettlePaymentRequest`
