// Gera tráfego de criação e consulta enquanto falhas são injetadas na Inventory API (LAB X1).
// A injeção é feita ANTES via scripts/fault.sh (ex.: scripts/fault.sh inventory http-503).
// Variáveis: BASE_URL, RATE (padrão 5), DURATION (padrão 3m), VUS, HTTP_TIMEOUT,
//            EXPECT_ERRORS (true => valida que 503 DEPENDENCY_UNAVAILABLE ocorreu)
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { assertWorkshopTarget, BASE_URL, createOrder, HTTP_TIMEOUT, int, orderPayload, uuid, RUN_ID } from './lib/common.js';

const dependencyUnavailable = new Counter('workshop_dependency_unavailable');
const circuitOpen = new Counter('workshop_circuit_open_rejections');
http.setResponseCallback(http.expectedStatuses(200, 201, 409));
const EXPECT_ERRORS = (__ENV.EXPECT_ERRORS || 'true') === 'true';

export const options = {
  scenarios: {
    errors: { executor: 'constant-arrival-rate', rate: int('RATE', 5), timeUnit: '1s', duration: __ENV.DURATION || '3m',
              preAllocatedVUs: int('VUS', 20), maxVUs: int('VUS', 20) * 4 },
  },
  thresholds: EXPECT_ERRORS ? { workshop_dependency_unavailable: ['count>0'] } : { http_req_failed: ['rate<0.05'] },
};

export function setup() { assertWorkshopTarget(); }

export default function () {
  const customer = `customer-${RUN_ID}-${Math.floor(Math.random() * 20)}`;
  const res = createOrder(customer, uuid(), orderPayload(customer));
  check(res, { 'resposta esperada (201/409/503)': (r) => [201, 409, 503].includes(r.status) });
  if (res.status === 503 && res.json('error') === 'DEPENDENCY_UNAVAILABLE') {
    dependencyUnavailable.add(1);
    if (res.json('reason') === 'circuit_open') circuitOpen.add(1);
  }
  const list = http.get(`${BASE_URL}/orders?customer_id=${customer}&limit=5`, { timeout: HTTP_TIMEOUT, tags: { name: 'GET /orders' } });
  check(list, { 'GET /orders 200/503': (r) => [200, 503].includes(r.status) });
}
