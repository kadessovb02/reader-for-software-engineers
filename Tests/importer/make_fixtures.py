from pathlib import Path
import zipfile, struct, zlib, base64, sys
root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / 'fixtures'
root.mkdir(parents=True, exist_ok=True)
container = '<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/book.opf"/></rootfiles></container>'
package = '''<?xml version="1.0"?><package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Тестовая книга</dc:title><dc:creator>Автор</dc:creator></metadata><manifest><item id="two" href="chapters/two.xhtml" media-type="application/xhtml+xml"/><item id="one" href="chapters/one.xhtml" media-type="application/xhtml+xml"/><item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>'''
entries = {'mimetype':'application/epub+zip','META-INF/container.xml':container,'OEBPS/book.opf':package,'OEBPS/chapters/one.xhtml':'<html><head><title>Общее название</title><style>body{color:red}</style></head><body onload="evil()"><h1>Первая глава</h1><p style="color:red">A &amp; B &#x2192; C</p><img src="../images/diagram.png"><script>evil()</script></body></html>','OEBPS/chapters/two.xhtml':'<html><body><h1>Вторая глава</h1><p>Текст два.</p><svg><path d="M0 0L10 10" style="stroke:black"/></svg></body></html>','OEBPS/toc.ncx':'<ncx><navMap><navPoint><navLabel><text>Из оглавления</text></navLabel><content src="chapters/one.xhtml#section"/></navPoint></navMap></ncx>','OEBPS/images/diagram.png':base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')}
with zipfile.ZipFile(root/'sample.epub','w',zipfile.ZIP_DEFLATED) as archive:
    for name,data in entries.items(): archive.writestr(name,data)
for name, badname in [('traversal','../outside.txt'),('absolute','/tmp/outside.txt'),('backslash','..\\outside.txt'),('case-duplicate','OEBPS/BOOK.OPF')]:
    with zipfile.ZipFile(root/f'{name}.epub','w',zipfile.ZIP_DEFLATED) as archive:
        for path,data in entries.items(): archive.writestr(path,data)
        archive.writestr(badname,'bad')
with zipfile.ZipFile(root/'symlink.epub','w') as archive:
    item=zipfile.ZipInfo('link'); item.create_system=3; item.external_attr=(0o120777<<16); archive.writestr(item,'/tmp')
with zipfile.ZipFile(root/'unicode-traversal.epub','w') as archive:
    item=zipfile.ZipInfo('safe.txt'); path=b'../outside.txt'; extra=b'\x01'+struct.pack('<I',zlib.crc32(b'safe.txt'))+path; item.extra=struct.pack('<HH',0x7075,len(extra))+extra; archive.writestr(item,'bad')
(root/'sample.fb2').write_text('''<?xml version="1.0"?><FictionBook xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>Книга FB2</book-title><author><first-name>Иван</first-name><last-name>Иванов</last-name></author></title-info></description><body><section><title><p>Часть 1</p></title><p>Вступление.</p><section><title><p>Глава 1</p></title><p>Привет, <strong>мир</strong>!</p><image l:href="#diagram"/></section><section><title><p>Глава 2</p></title><p>Второй раздел.</p></section></section></body><binary id="diagram" content-type="image/png">'''+base64.b64encode(entries['OEBPS/images/diagram.png']).decode()+'''</binary></FictionBook>''')
(root/'sample.md').write_text('# Первая\n\nТекст **жирный**.\n\n```swift\nlet a = 1 < 2\n# This is code\n```\n\n## Вторая\n\nДругой текст.\n')
(root/'sample.txt').write_text('Глава 1\n\nПервый текст.\n\nГлава 2\n\nВторой текст.')
(root/'cp1251.txt').write_bytes('Привет, мир.'.encode('cp1251'))
(root/'sample.html').write_text('<html><head><meta charset="utf-8"><title>Заголовок HTML</title></head><body><h1>Основной заголовок</h1><p onclick="x()" color="red" style="color:green">Текст</p><a href=javascript:evil()>bad</a><iframe>bad</iframe><script>bad</script></body></html>')
print(root)
# Intentionally under-report a deflated member in both headers: runtime output caps must stop it.
with zipfile.ZipFile(root/'forged-size.epub','w',zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('inflated.txt', b'A' * (2 * 1024 * 1024))
data = bytearray((root/'forged-size.epub').read_bytes())
struct.pack_into('<I', data, 22, 1)
central = data.find(b'PK\x01\x02')
struct.pack_into('<I', data, central + 24, 1)
(root/'forged-size.epub').write_bytes(data)
import subprocess
for ext in ('rtf', 'docx'):
    subprocess.run(['/usr/bin/textutil','-convert',ext,str(root/'sample.html'),'-output',str(root/f'sample.{ext}')], check=True, stdout=subprocess.DEVNULL)
(root/'utf16.txt').write_text('Привет UTF16.', encoding='utf-16')
