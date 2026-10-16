// Rampa de carga para o LAB 06 (HPA + Cluster Autoscaler).
// Variáveis: BASE_URL, RATE (pico req/s, padrão 60), DURATION (platô, padrão 6m), RAMP (padrão 1m),
//            VUS (pré-alocados, padrão 50), HTTP_TIMEOUT
import { sleep } from 'k6';
import { assertWorkshopTarget, checkCreated, createOrderWithRetry, int, orderPayload, RUN_ID } from './lib/common.js';

const PEAK = int('RATE', 60);

export const options = {
  scenarios: {
    stress: {
      executor: 'ramping-arrival-rate', startRate: Math.max(1, Math.floor(PEAK / 10)), timeUnit: '1s',
      preAllocatedVUs: int('VUS', 50), maxVUs: int('VUS', 50) * 6,
      stages: [
        { target: PEAK, duration: __ENV.RAMP || '1m' },
        { target: PEAK, duration: __ENV.DURATION || '6m' },
        { target: 0, duration: '30s' },
      ],
    },
  },
  // Sob estresse, erros são ESPERADOS e fazem parte da observação; não aborta o teste.
  thresholds: { http_req_failed: [{ threshold: 'rate<0.50', abortOnFail: false }] },
};

export function setup() { assertWorkshopTarget(); }

export default function () {
  const customer = `customer-${RUN_ID}-${Math.floor(Math.random() * 200)}`;
  checkCreated(createOrderWithRetry(customer, orderPayload(customer), 2, sleep).res);
}
