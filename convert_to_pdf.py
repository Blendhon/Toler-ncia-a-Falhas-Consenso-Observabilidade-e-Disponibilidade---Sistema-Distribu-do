import re
import pathlib
from fpdf import FPDF

MD_PATH = pathlib.Path(r"C:\Users\blend\OneDrive\Área de Trabalho\Trab Sis Dis\roteiro-apresentacao.md")
PDF_PATH = MD_PATH.with_suffix(".pdf")

FONT_DIR = pathlib.Path(r"C:\Users\blend\OneDrive\Área de Trabalho\Trab Sis Dis")

class RoteiroPDF(FPDF):
    def __init__(self):
        super().__init__()
        self.set_auto_page_break(auto=True, margin=25)
        self.add_font("DejaVu", "", "C:\\Windows\\Fonts\\tahoma.ttf", uni=True)
        self.add_font("DejaVu", "B", "C:\\Windows\\Fonts\\tahomabd.ttf", uni=True)
        self.add_font("Mono", "", "C:\\Windows\\Fonts\\consola.ttf", uni=True)

    def header(self):
        if self.page_no() > 1:
            self.set_font("DejaVu", "", 8)
            self.set_text_color(150, 150, 150)
            self.cell(0, 8, "Roteiro de Apresentacao - Sistemas Distribuidos 2026/1", align="C")
            self.ln(10)

    def footer(self):
        self.set_y(-20)
        self.set_font("DejaVu", "", 8)
        self.set_text_color(150, 150, 150)
        self.cell(0, 10, f"Pagina {self.page_no()}/{{nb}}", align="C")

    def section_title(self, title, level=1):
        if level == 1:
            self.set_font("DejaVu", "B", 18)
            self.set_text_color(26, 82, 118)
            self.ln(4)
            self.multi_cell(0, 10, title)
            self.set_draw_color(26, 82, 118)
            self.set_line_width(0.8)
            self.line(10, self.get_y(), 200, self.get_y())
            self.ln(6)
        elif level == 2:
            self.set_font("DejaVu", "B", 14)
            self.set_text_color(26, 82, 118)
            self.ln(3)
            self.multi_cell(0, 8, title)
            self.set_draw_color(200, 200, 200)
            self.set_line_width(0.3)
            self.line(10, self.get_y(), 200, self.get_y())
            self.ln(4)
        elif level == 3:
            self.set_font("DejaVu", "B", 11)
            self.set_text_color(44, 62, 80)
            self.ln(2)
            self.multi_cell(0, 7, title)
            self.ln(2)

    def body_text(self, text):
        self.set_font("DejaVu", "", 10)
        self.set_text_color(30, 30, 30)
        self.multi_cell(0, 6, text)
        self.ln(2)

    def bold_text(self, text):
        self.set_font("DejaVu", "B", 10)
        self.set_text_color(30, 30, 30)
        self.multi_cell(0, 6, text)
        self.ln(1)

    def quote_block(self, text):
        self.set_fill_color(234, 242, 248)
        x = self.get_x()
        y = self.get_y()
        self.set_font("DejaVu", "", 10)
        self.set_text_color(26, 82, 118)
        self.set_x(x + 4)
        w = self.w - self.l_margin - self.r_margin - 4
        self.multi_cell(w, 6, text, fill=True)
        self.ln(3)

    def code_block(self, code):
        self.set_fill_color(30, 30, 30)
        self.set_text_color(212, 212, 212)
        self.set_font("Mono", "", 8.5)
        x = self.get_x()
        y = self.get_y()
        lines = code.strip().split("\n")
        line_h = 5
        block_h = len(lines) * line_h + 8

        if self.get_y() + block_h > 270:
            self.add_page()

        self.rect(x, y, 190, block_h, "F")
        self.set_xy(x + 4, y + 4)
        for line in lines:
            self.cell(0, line_h, line)
            self.ln(line_h)
            self.set_x(x + 4)
        self.set_xy(x, y + block_h + 2)
        self.ln(2)

    def inline_code(self, text):
        self.set_font("Mono", "", 9)
        self.set_text_color(180, 50, 50)
        self.cell(0, 6, text)
        self.set_font("DejaVu", "", 10)
        self.set_text_color(30, 30, 30)

    def table_row(self, cells, is_header=False):
        if is_header:
            self.set_fill_color(26, 82, 118)
            self.set_text_color(255, 255, 255)
            self.set_font("DejaVu", "B", 9)
        else:
            self.set_fill_color(248, 249, 250)
            self.set_text_color(30, 30, 30)
            self.set_font("DejaVu", "", 9)

        col_widths = [190 / len(cells)] * len(cells)
        for i, cell in enumerate(cells):
            self.cell(col_widths[i], 7, cell.strip(), border=1, fill=True, align="L")
        self.ln()

    def separator(self):
        self.set_draw_color(26, 82, 118)
        self.set_line_width(0.5)
        y = self.get_y() + 2
        self.line(30, y, 180, y)
        self.ln(6)


def parse_and_render(pdf, md_text):
    lines = md_text.split("\n")
    i = 0
    in_code_block = False
    code_content = []
    in_table = False
    table_rows = []

    while i < len(lines):
        line = lines[i]

        # Code block start/end
        if line.strip().startswith("```"):
            if in_code_block:
                pdf.code_block("\n".join(code_content))
                code_content = []
                in_code_block = False
            else:
                in_code_block = True
            i += 1
            continue

        if in_code_block:
            code_content.append(line)
            i += 1
            continue

        # Table detection
        if "|" in line and line.strip().startswith("|"):
            cells = [c.strip() for c in line.strip().split("|") if c.strip()]
            if all(re.match(r'^[-:]+$', c) for c in cells):
                i += 1
                continue
            if not in_table:
                in_table = True
                table_rows = []
            table_rows.append(cells)
            i += 1
            # Check if next line is still table
            if i < len(lines) and "|" in lines[i] and lines[i].strip().startswith("|"):
                continue
            else:
                # End of table
                if table_rows:
                    pdf.table_row(table_rows[0], is_header=True)
                    for row in table_rows[1:]:
                        pdf.table_row(row)
                in_table = False
                table_rows = []
                pdf.ln(2)
                i += 0
                continue

        # Horizontal rule
        if re.match(r'^---+\s*$', line.strip()):
            pdf.separator()
            i += 1
            continue

        # Headers
        m = re.match(r'^(#{1,4})\s+(.*)', line)
        if m:
            level = len(m.group(1))
            text = m.group(2).strip()
            pdf.section_title(text, level=level)
            i += 1
            continue

        # Blockquote
        if line.strip().startswith(">"):
            quote_lines = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                quote_lines.append(re.sub(r'^>\s*', '', lines[i].strip()))
                i += 1
            pdf.quote_block(" ".join(quote_lines))
            continue

        # Empty line
        if line.strip() == "":
            i += 1
            continue

        # Regular text
        text = line.strip()
        # Simple bold handling
        text = re.sub(r'\*\*(.*?)\*\*', r'\1', text)
        text = re.sub(r'\*(.*?)\*', r'\1', text)
        pdf.body_text(text)
        i += 1


def main():
    md_text = MD_PATH.read_text(encoding="utf-8")

    pdf = RoteiroPDF()
    pdf.alias_nb_pages()
    pdf.add_page()

    parse_and_render(pdf, md_text)

    pdf.output(str(PDF_PATH))
    print(f"PDF gerado com sucesso: {PDF_PATH}")


if __name__ == "__main__":
    main()
