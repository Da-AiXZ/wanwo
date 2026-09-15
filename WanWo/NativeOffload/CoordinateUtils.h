//
//  CoordinateUtils.h
//  WanWo
//
//  【vendored 复用 · 源=OpenMinis src/ios/NativeOffloads/CoordinateUtils.h
//   全文 67 行，语义 1:1 零改动】WGS-84 <-> GCJ-02 坐标转换工具（header-only，
//   无 .m）。GCJ-02 为中国大陆地图服务坐标系；CLLocationManager 返回 WGS-84，
//   MapKit 在中国返回 GCJ-02。
//  适配点：仅文件头注释 MinisApp → WanWo（§十三.8 改名纪律）。
//

#ifndef CoordinateUtils_h
#define CoordinateUtils_h

#import <CoreLocation/CoreLocation.h>
#import <math.h>

static const double GCJ_A = 6378245.0;
static const double GCJ_EE = 0.00669342162296594323;

static inline BOOL gcj_isOutOfChina(double lat, double lon) {
    return (lon < 72.004 || lon > 137.8347 || lat < 0.8293 || lat > 55.8271);
}

static inline double gcj_transformLat(double x, double y) {
    double ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(fabs(x));
    ret += (20.0 * sin(6.0 * x * M_PI) + 20.0 * sin(2.0 * x * M_PI)) * 2.0 / 3.0;
    ret += (20.0 * sin(y * M_PI) + 40.0 * sin(y / 3.0 * M_PI)) * 2.0 / 3.0;
    ret += (160.0 * sin(y / 12.0 * M_PI) + 320.0 * sin(y * M_PI / 30.0)) * 2.0 / 3.0;
    return ret;
}

static inline double gcj_transformLon(double x, double y) {
    double ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(fabs(x));
    ret += (20.0 * sin(6.0 * x * M_PI) + 20.0 * sin(2.0 * x * M_PI)) * 2.0 / 3.0;
    ret += (20.0 * sin(x * M_PI) + 40.0 * sin(x / 3.0 * M_PI)) * 2.0 / 3.0;
    ret += (150.0 * sin(x / 12.0 * M_PI) + 300.0 * sin(x / 30.0 * M_PI)) * 2.0 / 3.0;
    return ret;
}

/// Convert WGS-84 to GCJ-02. Returns the input unchanged if outside China.
static inline CLLocationCoordinate2D wgs84_to_gcj02(double wgsLat, double wgsLon) {
    if (gcj_isOutOfChina(wgsLat, wgsLon)) {
        return CLLocationCoordinate2DMake(wgsLat, wgsLon);
    }
    double dLat = gcj_transformLat(wgsLon - 105.0, wgsLat - 35.0);
    double dLon = gcj_transformLon(wgsLon - 105.0, wgsLat - 35.0);
    double radLat = wgsLat / 180.0 * M_PI;
    double magic = sin(radLat);
    magic = 1 - GCJ_EE * magic * magic;
    double sqrtMagic = sqrt(magic);
    dLat = (dLat * 180.0) / ((GCJ_A * (1 - GCJ_EE)) / (magic * sqrtMagic) * M_PI);
    dLon = (dLon * 180.0) / (GCJ_A / sqrtMagic * cos(radLat) * M_PI);
    return CLLocationCoordinate2DMake(wgsLat + dLat, wgsLon + dLon);
}

/// Convert GCJ-02 to WGS-84 (iterative, ~0.5m accuracy).
static inline CLLocationCoordinate2D gcj02_to_wgs84(double gcjLat, double gcjLon) {
    if (gcj_isOutOfChina(gcjLat, gcjLon)) {
        return CLLocationCoordinate2DMake(gcjLat, gcjLon);
    }
    CLLocationCoordinate2D gcj = wgs84_to_gcj02(gcjLat, gcjLon);
    double dLat = gcj.latitude - gcjLat;
    double dLon = gcj.longitude - gcjLon;
    return CLLocationCoordinate2DMake(gcjLat - dLat, gcjLon - dLon);
}

#endif /* CoordinateUtils_h */
