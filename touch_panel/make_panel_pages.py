from pathlib import Path
import csv
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).parent / "pages"
OUT.mkdir(parents=True, exist_ok=True)
W, H = 480, 272
BG = "#F4F7F8"
INK = "#172B36"
MUTED = "#5B6D76"
TEAL = "#0C746F"
BLUE = "#235B8A"
RED = "#B5413D"

FONT = "C:/Windows/Fonts/msyh.ttc"
COMPONENTS = []


def f(size, bold=False):
    path = "C:/Windows/Fonts/msyhbd.ttc" if bold else FONT
    return ImageFont.truetype(path, size)


def text(draw, xy, value, size=18, fill=INK, bold=False, anchor=None):
    draw.text(xy, value, font=f(size, bold), fill=fill, anchor=anchor)


def page(num, title, subtitle=""):
    im = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, W, 8), fill=TEAL if num != 9 else RED)
    text(d, (20, 18), title, 23, INK, True)
    if subtitle:
        text(d, (20, 53), subtitle, 13, MUTED)
    d.line((20, 80, 460, 80), fill="#D9E3E6", width=1)
    return im, d


def button(d, box, label, tone="light", small=False):
    colors = {
        "light": ("#FFFFFF", "#CCD9DE", INK),
        "teal": (TEAL, TEAL, "#FFFFFF"),
        "blue": (BLUE, BLUE, "#FFFFFF"),
        "red": (RED, RED, "#FFFFFF"),
    }
    bg, line, fg = colors[tone]
    d.rounded_rectangle(box, radius=7, fill=bg, outline=line, width=2)
    x0, y0, x1, y1 = box
    text(d, ((x0+x1)//2, (y0+y1)//2), label, 16 if small else 18,
         fg, True, anchor="mm")


def save(num, title, subtitle, buttons, extra=None):
    im, d = page(num, title, subtitle)
    if extra:
        extra(d)
    for _, box, label, tone in buttons:
        button(d, box, label, tone, small=len(label)>8)
    for component, box, label, _ in buttons:
        COMPONENTS.append((num, component, *box, label))
    im.save(OUT / f"page_{num:02d}.png")


save(0, "欢迎使用", "离线交互式科技馆导览", [
    (1, (60, 109, 420, 186), "开始参观", "teal")])
save(1, "选择导览方式", "主画面同步显示所选项目", [
    (1, (20, 94, 460, 135), "手动浏览", "teal"),
    (2, (20, 146, 235, 203), "自动导览", "blue"),
    (3, (245, 146, 460, 203), "自选路线", "blue"),
    (4, (20, 212, 82, 254), "左", "light"),
    (5, (88, 212, 150, 254), "右", "light"),
    (6, (156, 212, 218, 254), "上", "light"),
    (7, (224, 212, 286, 254), "下", "light"),
    (8, (292, 212, 372, 254), "确认", "light"),
    (9, (378, 212, 460, 254), "取消", "light")])
save(2, "自动导览", "路线高亮同步显示在 HDMI 画面", [
    (1, (20, 98, 225, 157), "完整导览", "blue"),
    (2, (235, 98, 460, 157), "自选路线", "light"),
    (4, (20, 175, 305, 241), "开始播放", "teal"),
    (3, (320, 175, 460, 241), "返回", "light")])
routes = ["虚拟现实 + 天文观测", "虚拟现实 + 生命展陈", "虚拟现实 + 光声实验",
          "天文观测 + 生命展陈", "天文观测 + 光声实验", "生命展陈 + 光声实验"]
route_buttons = []
for i, label in enumerate(routes):
    col, row = i%2, i//2
    x = 20 if col==0 else 246
    route_buttons.append((i+1, (x, 89+row*46, x+214, 128+row*46), label, "light"))
route_buttons += [(7, (20, 229, 155, 264), "确认路线", "teal"),
                  (8, (164, 229, 265, 264), "返回", "light"),
                  (9, (274, 229, 315, 264), "左", "light"),
                  (10, (324, 229, 365, 264), "右", "light")]
save(3, "自选导览路线", "点选路线，HDMI 同步高亮，然后确认", route_buttons)
save(4, "手动浏览", "地图与展项的热点提示见 HDMI 画面", [
    (2, (20, 90, 225, 133), "上一页", "light"),
    (1, (235, 90, 460, 133), "下一页", "teal"),
    (3, (20, 142, 165, 184), "热点选择", "blue"),
    (4, (173, 142, 313, 184), "ROI 选区", "blue"),
    (5, (322, 142, 460, 184), "返回菜单", "light"),
    (6, (20, 193, 76, 233), "左", "light"),
    (7, (82, 193, 138, 233), "右", "light"),
    (8, (144, 193, 200, 233), "上", "light"),
    (9, (206, 193, 262, 233), "下", "light"),
    (10, (268, 193, 345, 233), "确认", "light"),
    (11, (352, 193, 430, 233), "取消", "light"),
    (12, (20, 239, 177, 270), "画面与音量调节", "light")])
save(5, "选择展项热点", "触摸热点后在 HDMI 画面查看高亮", [
    (1, (20, 94, 235, 153), "热点 1", "blue"),
    (2, (245, 94, 460, 153), "热点 2", "blue"),
    (3, (20, 162, 235, 221), "地图热点 3", "blue"),
    (4, (245, 162, 460, 221), "地图热点 4", "blue"),
    (5, (20, 228, 237, 268), "播放所选详情", "teal"),
    (6, (245, 228, 460, 268), "取消", "light")])
save(6, "热点详情", "地图页可前往该展项的专属讲解", [
    (1, (20, 94, 460, 143), "地图页前往该展项", "teal"),
    (2, (20, 151, 235, 200), "重播讲解", "blue"),
    (3, (245, 151, 460, 200), "返回选择", "light"),
    (4, (20, 210, 130, 260), "下一页", "light"),
    (5, (140, 210, 250, 260), "上一页", "light"),
    (6, (260, 210, 460, 260), "返回菜单", "light")])
save(7, "自动导览中", "字幕与当前播放状态仍显示于 HDMI", [
    (1, (20, 95, 460, 148), "暂停 / 继续", "teal"),
    (2, (20, 158, 235, 207), "下一页", "light"),
    (3, (245, 158, 460, 207), "上一页", "light"),
    (4, (20, 217, 460, 266), "返回菜单", "light")])
save(8, "ROI 选区", "选区和缩略概览在 HDMI 画面显示", [
    (1, (20, 94, 126, 144), "左", "light"),
    (2, (132, 94, 238, 144), "右", "light"),
    (3, (244, 94, 350, 144), "上", "light"),
    (4, (356, 94, 460, 144), "下", "light"),
    (5, (20, 157, 234, 207), "确认放大", "teal"),
    (6, (246, 157, 460, 207), "取消", "light"),
    (7, (20, 217, 235, 265), "切换 ROI", "blue"),
    (8, (245, 217, 460, 265), "返回菜单", "light")])
save(9, "应急疏散", "请按照 HDMI 上的预设疏散路线行动", [
    (1, (20, 104, 460, 185), "退出应急界面", "red")])
save(10, "画面与音量调节", "选取项目后使用加减按钮", [
    (1, (20, 92, 162, 142), "音量", "blue"),
    (2, (169, 92, 311, 142), "亮度", "blue"),
    (3, (318, 92, 460, 142), "对比度", "blue"),
    (4, (20, 158, 235, 217), "增加", "teal"),
    (5, (245, 158, 460, 217), "减少", "light"),
    (6, (20, 228, 460, 268), "完成", "light")])
save(11, "完整导览 · 讲解方式", "点选后查看 HDMI 高亮，再按开始播放", [
    (1, (20, 92, 460, 134), "有讲解 · 逐页讲解后返回菜单", "blue"),
    (2, (20, 143, 460, 185), "无讲解 · 背景音乐 / 三秒轮播", "light"),
    (3, (20, 201, 205, 259), "开始播放", "teal"),
    (4, (214, 201, 324, 259), "返回", "light"),
    (5, (334, 201, 392, 259), "上", "light"),
    (6, (402, 201, 460, 259), "下", "light")])
with (OUT.parent / "component_map.csv").open("w", newline="", encoding="utf-8-sig") as stream:
    writer = csv.writer(stream)
    writer.writerow(("page_id", "component_id", "x0", "y0", "x1", "y1", "label"))
    writer.writerows(sorted(COMPONENTS))
print(f"Wrote 12 panel backgrounds to {OUT}")
