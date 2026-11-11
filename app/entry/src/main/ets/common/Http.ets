import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { cachePut, cacheRead, cacheReadStale } from './PageCache';

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

/**
 * 带页面缓存的 GET（用户第 9 条）。
 *
 * 命中未过期缓存就直接返回，**不发请求**——列表页/详情页第二次进来时
 * 第一帧就有内容，不会先转圈再等一次网络。缓存未命中或已过期才走网络，
 * 回来顺手落缓存（内存 + 磁盘，退出 App 再进来还在）。
 *
 * 写操作（POST/PUT/DELETE）永远不走这里：它们会改数据，缓存必须失效。
 */
export async function httpGetCached(url: string, token: string,
  ttlMs: number = 600000): Promise<string> {
  const hit: string | undefined = cacheRead(url);
  if (hit !== undefined) {
    return hit;
  }
  const text: string = await httpGet(url, token);
  cachePut(url, text, ttlMs);
  return text;
}

/** 缓存里有没有（不看是否过期）：页面首屏可以先拿它渲染。 */
export function cachedBody(url: string): string | undefined {
  return cacheReadStale(url);
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

/**
 * 取二进制（图片）：截帧「存到手机」要把它落到沙箱。
 *
 * 不走 call()：那边统一 `expectDataType: STRING`，二进制会被转成乱码字符串。
 * 读取超时给得比 JSON 宽（大图 + 网盘源可能慢）。
 */
export async function httpGetBytes(url: string, token: string): Promise<ArrayBuffer> {
  const request = http.createHttp();
  try {
    const header: Record<string, string> = {};
    if (token.length > 0) {
      header['Authorization'] = `Bearer ${token}`;
    }
    const response: http.HttpResponse = await request.request(url, {
      method: http.RequestMethod.GET,
      header: header,
      connectTimeout: 8000,
      readTimeout: 60000,
      usingCache: false,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    });
    if (response.responseCode >= 400) {
      throw new HttpError(response.responseCode, `HTTP ${response.responseCode}`);
    }
    return response.result as ArrayBuffer;
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
