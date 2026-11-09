import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 一次 HTTP 调用的结果。服务端约定是 JSON，失败时抛 HttpError。 */
export class HttpError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

async function call(url: string, method: http.RequestMethod, token: string, body: string): Promise<string> {
  const request = http.createHttp();
  try {
    const header: Record<string, string> = {};
    header['Content-Type'] = 'application/json';
    if (token.length > 0) {
      header['Authorization'] = `Bearer ${token}`;
    }
    const options: http.HttpRequestOptions = {
      method: method,
      header: header,
      connectTimeout: 8000,
      readTimeout: 25000,
      usingCache: false,
      expectDataType: http.HttpDataType.STRING
    };
    if (body.length > 0) {
      options.extraData = body;
    }
    const response: http.HttpResponse = await request.request(url, options);
    const text: string = typeof response.result === 'string' ? response.result as string : '';
    if (response.responseCode >= 400) {
      throw new HttpError(response.responseCode, text.length > 0 ? text : `HTTP ${response.responseCode}`);
    }
    return text;
  } catch (error) {
    if (error instanceof HttpError) {
      throw error;
    }
    const err = error as BusinessError;
    throw new HttpError(-1, `${err.code}: ${err.message}`);
  } finally {
    request.destroy();
  }
}

export async function httpGet(url: string, token: string): Promise<string> {
  return call(url, http.RequestMethod.GET, token, '');
}

export async function httpPost(url: string, token: string, body: string): Promise<string> {
  return call(url, http.RequestMethod.POST, token, body);
}

export async function httpPut(url: string, token: string, body: string): Promise<string> {
  return call(url, http.RequestMethod.PUT, token, body);
}

export async function httpDelete(url: string, token: string): Promise<string> {
  return call(url, http.RequestMethod.DELETE, token, '');
}

/** 探活：拿到任意 HTTP 响应就算可达（401 也算）。 */
export function probe(url: string, timeoutMs: number): Promise<boolean> {
  return new Promise<boolean>((resolve: (ok: boolean) => void) => {
    const request = http.createHttp();
    let settled: boolean = false;
    const finish = (ok: boolean): void => {
      if (settled) {
        return;
      }
      settled = true;
      try {
        request.destroy();
      } catch (error) {
        const err = error as BusinessError;
        console.error(`[amane] probe destroy: ${err.code}`);
      }
      resolve(ok);
    };
    const timer: number = setTimeout(() => {
      finish(false);
    }, timeoutMs);
    request.request(url, {
      method: http.RequestMethod.GET,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      usingCache: false
    }).then((response: http.HttpResponse) => {
      clearTimeout(timer);
      finish(response.responseCode > 0);
    }).catch((error: BusinessError) => {
      clearTimeout(timer);
      console.info(`[amane] probe ${url} failed: ${error.code}`);
      finish(false);
    });
  });
}
