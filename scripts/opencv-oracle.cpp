// opencv-oracle, a command-line tool of meziantou/prebuilt built with OpenCV
// (scripts/build-opencv.sh): it runs one OpenCV function on an image or a set
// of points, and prints the result as JSON, so that other implementations can
// be compared with OpenCV.
//
//   opencv-oracle --version
//   opencv-oracle hough-lines <image> <rho> <theta> <threshold>
//   opencv-oracle hough-lines-p <image> <rho> <theta> <threshold> <minLineLength> <maxLineGap>
//   opencv-oracle harris <image> <blockSize> <ksize> <k> [<response.raw>]
//   opencv-oracle good-features <image> <maxCorners> <qualityLevel> <minDistance> <blockSize> <useHarris 0|1> <k>
//   opencv-oracle fast <image> <threshold> <nonmaxSuppression 0|1> <5_8|7_12|9_16>
//   opencv-oracle homography <points.txt> <dlt|ransac|lmeds|rho> <reprojectionThreshold> <seed>
//   opencv-oracle inpaint <image> <mask> <radius> <telea|ns> <output>
//
// <image> is a PNG file (any file cv::imread reads; 8-bit gray or BGR as
// stored), or raw samples: raw:<width>:<height>:<channels>:<file>, unsigned
// 8-bit, interleaved, row by row. hough-lines, hough-lines-p, harris,
// good-features and fast take a single-channel image (a color image is
// converted with cv::cvtColor BGR2GRAY). <output> is a PNG file, or raw:<file>
// for raw samples.
//
// The JSON (one object, numbers with 9 significant digits):
//   hough-lines     {"lines": [[rho, theta, votes], ...]}   cv::HoughLines
//   hough-lines-p   {"lines": [[x1, y1, x2, y2], ...]}      cv::HoughLinesP
//   harris          {"width", "height", "min", "max", "maxLocation": [x, y]}
//                   cv::cornerHarris; <response.raw> gets the response, 32-bit
//                   little-endian floats, row by row
//   good-features   {"corners": [[x, y], ...]}              cv::goodFeaturesToTrack
//   fast            {"keypoints": [[x, y, response], ...]}  cv::FAST
//   homography      {"homography": [9 values, row by row], "inliers": [0|1, ...]}
//                   cv::findHomography with method 0 (dlt), RANSAC, LMEDS or
//                   RHO, after cv::setRNGSeed(<seed>); <points.txt> has one
//                   "x y x' y'" line per correspondence. "homography" is null
//                   when OpenCV finds none.
//   inpaint         {"width", "height", "channels"}         cv::inpaint
//                   (INPAINT_TELEA or INPAINT_NS) of the 8-bit image where the
//                   8-bit mask is not 0
//
// The parallel framework of OpenCV is not built: every function runs on one
// thread, and gives the same values on every run.

#include <opencv2/calib3d.hpp>
#include <opencv2/core.hpp>
#include <opencv2/core/utility.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/photo.hpp>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace
{
[[noreturn]] void Fail(const std::string& message)
{
    std::fprintf(stderr, "opencv-oracle: %s\n", message.c_str());
    std::exit(1);
}

double Number(const char* text, const char* name)
{
    char* end = nullptr;
    double value = std::strtod(text, &end);
    if (end == text || *end != '\0')
        Fail(std::string("invalid ") + name + ": " + text);
    return value;
}

int Integer(const char* text, const char* name)
{
    double value = Number(text, name);
    if (value != static_cast<int>(value))
        Fail(std::string("invalid ") + name + ": " + text);
    return static_cast<int>(value);
}

std::string Json(double value)
{
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.9g", value);
    return buffer;
}

bool StartsWith(const std::string& text, const std::string& prefix)
{
    return text.compare(0, prefix.size(), prefix) == 0;
}

std::vector<char> ReadFile(const std::string& path)
{
    std::ifstream stream(path, std::ios::binary);
    if (!stream)
        Fail("cannot read " + path);
    return std::vector<char>((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
}

void WriteFile(const std::string& path, const void* data, size_t size)
{
    std::ofstream stream(path, std::ios::binary);
    if (!stream || !stream.write(static_cast<const char*>(data), static_cast<std::streamsize>(size)))
        Fail("cannot write " + path);
}

// A PNG file, or raw:<width>:<height>:<channels>:<file>.
cv::Mat ReadImage(const std::string& spec)
{
    if (StartsWith(spec, "raw:"))
    {
        int width = 0, height = 0, channels = 0;
        char path[4096] = {0};
        if (std::sscanf(spec.c_str(), "raw:%d:%d:%d:%4095[^\n]", &width, &height, &channels, path) != 4 ||
            width <= 0 || height <= 0 || channels < 1 || channels > 4)
            Fail("invalid raw image: " + spec + " (raw:<width>:<height>:<channels>:<file>)");
        std::vector<char> data = ReadFile(path);
        size_t expected = static_cast<size_t>(width) * height * channels;
        if (data.size() != expected)
            Fail(std::string(path) + " has " + std::to_string(data.size()) + " bytes, not " + std::to_string(expected));
        cv::Mat image(height, width, CV_8UC(channels));
        std::memcpy(image.data, data.data(), expected);
        return image;
    }

    cv::Mat image = cv::imread(spec, cv::IMREAD_UNCHANGED);
    if (image.empty())
        Fail("cannot read the image " + spec);
    if (image.depth() != CV_8U)
        Fail(spec + " is not an 8-bit image");
    return image;
}

cv::Mat Gray(const cv::Mat& image)
{
    if (image.channels() == 1)
        return image;
    cv::Mat gray;
    cv::cvtColor(image, gray, image.channels() == 4 ? cv::COLOR_BGRA2GRAY : cv::COLOR_BGR2GRAY);
    return gray;
}

void WriteImage(const std::string& spec, const cv::Mat& image)
{
    if (StartsWith(spec, "raw:"))
    {
        cv::Mat continuous = image.isContinuous() ? image : image.clone();
        WriteFile(spec.substr(4), continuous.data, continuous.total() * continuous.elemSize());
        return;
    }

    if (!cv::imwrite(spec, image))
        Fail("cannot write the image " + spec);
}

void Usage()
{
    std::fprintf(stderr,
        "usage: opencv-oracle --version\n"
        "       opencv-oracle hough-lines <image> <rho> <theta> <threshold>\n"
        "       opencv-oracle hough-lines-p <image> <rho> <theta> <threshold> <minLineLength> <maxLineGap>\n"
        "       opencv-oracle harris <image> <blockSize> <ksize> <k> [<response.raw>]\n"
        "       opencv-oracle good-features <image> <maxCorners> <qualityLevel> <minDistance> <blockSize> <useHarris 0|1> <k>\n"
        "       opencv-oracle fast <image> <threshold> <nonmaxSuppression 0|1> <5_8|7_12|9_16>\n"
        "       opencv-oracle homography <points.txt> <dlt|ransac|lmeds|rho> <reprojectionThreshold> <seed>\n"
        "       opencv-oracle inpaint <image> <mask> <radius> <telea|ns> <output>\n"
        "<image>: a PNG file, or raw:<width>:<height>:<channels>:<file>\n");
    std::exit(2);
}

int HoughLines(int argc, char** argv)
{
    if (argc != 6)
        Usage();
    cv::Mat image = Gray(ReadImage(argv[2]));
    std::vector<cv::Vec3f> lines;
    cv::HoughLines(image, lines, Number(argv[3], "rho"), Number(argv[4], "theta"), Integer(argv[5], "threshold"));
    std::string json = "{\"lines\": [";
    for (size_t i = 0; i < lines.size(); i++)
        json += (i ? ", [" : "[") + Json(lines[i][0]) + ", " + Json(lines[i][1]) + ", " + Json(lines[i][2]) + "]";
    std::printf("%s]}\n", json.c_str());
    return 0;
}

int HoughLinesP(int argc, char** argv)
{
    if (argc != 8)
        Usage();
    cv::Mat image = Gray(ReadImage(argv[2]));
    std::vector<cv::Vec4i> lines;
    cv::HoughLinesP(image, lines, Number(argv[3], "rho"), Number(argv[4], "theta"), Integer(argv[5], "threshold"),
                    Number(argv[6], "minLineLength"), Number(argv[7], "maxLineGap"));
    std::string json = "{\"lines\": [";
    for (size_t i = 0; i < lines.size(); i++)
        json += (i ? ", [" : "[") + std::to_string(lines[i][0]) + ", " + std::to_string(lines[i][1]) + ", " +
                std::to_string(lines[i][2]) + ", " + std::to_string(lines[i][3]) + "]";
    std::printf("%s]}\n", json.c_str());
    return 0;
}

int Harris(int argc, char** argv)
{
    if (argc != 6 && argc != 7)
        Usage();
    cv::Mat image = Gray(ReadImage(argv[2]));
    cv::Mat response;
    cv::cornerHarris(image, response, Integer(argv[3], "blockSize"), Integer(argv[4], "ksize"), Number(argv[5], "k"));
    double minimum = 0, maximum = 0;
    cv::Point maxLocation;
    cv::minMaxLoc(response, &minimum, &maximum, nullptr, &maxLocation);
    if (argc == 7)
        WriteImage(std::string("raw:") + argv[6], response);
    std::printf("{\"width\": %d, \"height\": %d, \"min\": %s, \"max\": %s, \"maxLocation\": [%d, %d]}\n",
                response.cols, response.rows, Json(minimum).c_str(), Json(maximum).c_str(), maxLocation.x, maxLocation.y);
    return 0;
}

int GoodFeatures(int argc, char** argv)
{
    if (argc != 9)
        Usage();
    cv::Mat image = Gray(ReadImage(argv[2]));
    std::vector<cv::Point2f> corners;
    cv::goodFeaturesToTrack(image, corners, Integer(argv[3], "maxCorners"), Number(argv[4], "qualityLevel"),
                            Number(argv[5], "minDistance"), cv::noArray(), Integer(argv[6], "blockSize"),
                            Integer(argv[7], "useHarris") != 0, Number(argv[8], "k"));
    std::string json = "{\"corners\": [";
    for (size_t i = 0; i < corners.size(); i++)
        json += (i ? ", [" : "[") + Json(corners[i].x) + ", " + Json(corners[i].y) + "]";
    std::printf("%s]}\n", json.c_str());
    return 0;
}

int Fast(int argc, char** argv)
{
    if (argc != 6)
        Usage();
    cv::Mat image = Gray(ReadImage(argv[2]));
    cv::FastFeatureDetector::DetectorType type;
    std::string name = argv[5];
    if (name == "5_8")
        type = cv::FastFeatureDetector::TYPE_5_8;
    else if (name == "7_12")
        type = cv::FastFeatureDetector::TYPE_7_12;
    else if (name == "9_16")
        type = cv::FastFeatureDetector::TYPE_9_16;
    else
        Fail("invalid FAST type: " + name + " (5_8, 7_12 or 9_16)");
    std::vector<cv::KeyPoint> keypoints;
    cv::FAST(image, keypoints, Integer(argv[3], "threshold"), Integer(argv[4], "nonmaxSuppression") != 0, type);
    std::string json = "{\"keypoints\": [";
    for (size_t i = 0; i < keypoints.size(); i++)
        json += (i ? ", [" : "[") + Json(keypoints[i].pt.x) + ", " + Json(keypoints[i].pt.y) + ", " + Json(keypoints[i].response) + "]";
    std::printf("%s]}\n", json.c_str());
    return 0;
}

int Homography(int argc, char** argv)
{
    if (argc != 6)
        Usage();
    std::vector<cv::Point2f> source, destination;
    std::ifstream stream(argv[2]);
    if (!stream)
        Fail(std::string("cannot read ") + argv[2]);
    std::string line;
    while (std::getline(stream, line))
    {
        if (line.find_first_not_of(" \t\r") == std::string::npos)
            continue;
        std::istringstream values(line);
        float x, y, x2, y2;
        if (!(values >> x >> y >> x2 >> y2))
            Fail("invalid correspondence: " + line + " (x y x' y')");
        source.emplace_back(x, y);
        destination.emplace_back(x2, y2);
    }

    std::string name = argv[3];
    int method;
    if (name == "dlt")
        method = 0;
    else if (name == "ransac")
        method = cv::RANSAC;
    else if (name == "lmeds")
        method = cv::LMEDS;
    else if (name == "rho")
        method = cv::RHO;
    else
        Fail("invalid method: " + name + " (dlt, ransac, lmeds or rho)");

    cv::setRNGSeed(Integer(argv[5], "seed"));
    std::vector<unsigned char> mask;
    cv::Mat homography = cv::findHomography(source, destination, method, Number(argv[4], "reprojectionThreshold"), mask);
    std::string json = "{\"homography\": ";
    if (homography.empty())
        json += "null";
    else
    {
        json += "[";
        for (int i = 0; i < 9; i++)
            json += (i ? ", " : "") + Json(homography.at<double>(i / 3, i % 3));
        json += "]";
    }
    json += ", \"inliers\": [";
    for (size_t i = 0; i < mask.size(); i++)
        json += (i ? ", " : "") + std::to_string(mask[i] ? 1 : 0);
    std::printf("%s]}\n", json.c_str());
    return 0;
}

int Inpaint(int argc, char** argv)
{
    if (argc != 7)
        Usage();
    cv::Mat image = ReadImage(argv[2]);
    cv::Mat mask = Gray(ReadImage(argv[3]));
    std::string name = argv[5];
    int method;
    if (name == "telea")
        method = cv::INPAINT_TELEA;
    else if (name == "ns")
        method = cv::INPAINT_NS;
    else
        Fail("invalid method: " + name + " (telea or ns)");
    cv::Mat result;
    cv::inpaint(image, mask, result, Number(argv[4], "radius"), method);
    WriteImage(argv[6], result);
    std::printf("{\"width\": %d, \"height\": %d, \"channels\": %d}\n", result.cols, result.rows, result.channels());
    return 0;
}
}

int main(int argc, char** argv)
{
    if (argc < 2)
        Usage();
    std::string command = argv[1];
    if (command == "--version")
    {
        std::printf("opencv-oracle (OpenCV %s)\n", CV_VERSION);
        return 0;
    }

    try
    {
        cv::setNumThreads(1);
        if (command == "hough-lines")
            return HoughLines(argc, argv);
        if (command == "hough-lines-p")
            return HoughLinesP(argc, argv);
        if (command == "harris")
            return Harris(argc, argv);
        if (command == "good-features")
            return GoodFeatures(argc, argv);
        if (command == "fast")
            return Fast(argc, argv);
        if (command == "homography")
            return Homography(argc, argv);
        if (command == "inpaint")
            return Inpaint(argc, argv);
    }
    catch (const cv::Exception& exception)
    {
        Fail(exception.what());
    }

    Usage();
}
