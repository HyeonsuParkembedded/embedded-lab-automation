import asyncio
import os
import subprocess
import sys
from typing import Optional
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

# ESP-IDF MCP Server
# 역할: 에이전트가 idf.py 명령을 직접 실행할 수 있도록 도구 제공
# 위치: ~/embedded-lab/mcp-servers/esp_idf_mcp.py

server = Server("esp-idf-mcp")

def run_idf_command(project_path: str, args: list) -> str:
    """idf.py 명령어를 실행하고 결과를 반환합니다."""
    # 윈도우와 리눅스 대응
    # 윈도우는 idf.py가 아니라 idf.py.exe 혹은 셸 환경 로드가 필요할 수 있음
    cmd = ["idf.py"] + args
    
    try:
        # 프로젝트 경로로 이동하여 실행
        result = subprocess.run(
            cmd,
            cwd=project_path,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            shell=True if os.name == 'nt' else False
        )
        return result.stdout
    except Exception as e:
        return f"명령 실행 중 오류 발생: {str(e)}"

@server.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="build",
            description="ESP-IDF 프로젝트를 빌드합니다.",
            inputSchema={
                "type": "object",
                "properties": {
                    "project_path": {"type": "string", "description": "프로젝트 디렉토리 절대 경로"},
                    "target": {"type": "string", "description": "빌드 타겟 (esp32, esp32s3 등)", "default": "esp32"}
                },
                "required": ["project_path"]
            }
        ),
        Tool(
            name="flash",
            description="빌드된 바이너리를 보드에 업로드합니다.",
            inputSchema={
                "type": "object",
                "properties": {
                    "project_path": {"type": "string", "description": "프로젝트 디렉토리 절대 경로"},
                    "port": {"type": "string", "description": "시리얼 포트 경로 (예: /dev/ttyUSB0 또는 COM3)"},
                    "baud": {"type": "string", "description": "보드레이트", "default": "115200"}
                },
                "required": ["project_path", "port"]
            }
        ),
        Tool(
            name="get_size",
            description="바이너리 크기 정보를 확인합니다.",
            inputSchema={
                "type": "object",
                "properties": {
                    "project_path": {"type": "string", "description": "프로젝트 디렉토리 절대 경로"}
                },
                "required": ["project_path"]
            }
        ),
        Tool(
            name="clean",
            description="빌드 출력물을 삭제합니다.",
            inputSchema={
                "type": "object",
                "properties": {
                    "project_path": {"type": "string", "description": "프로젝트 디렉토리 절대 경로"}
                },
                "required": ["project_path"]
            }
        )
    ]

@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    project_path = arguments.get("project_path")
    
    if not project_path:
        return [TextContent(type="text", text="오류: project_path가 필요합니다.")]

    if name == "build":
        target = arguments.get("target", "esp32")
        # 타겟 설정 후 빌드
        set_target_out = run_idf_command(project_path, ["set-target", target])
        build_out = run_idf_command(project_path, ["build"])
        return [TextContent(type="text", text=f"### Target Setting
{set_target_out}

### Build Output
{build_out}")]

    elif name == "flash":
        port = arguments.get("port")
        baud = arguments.get("baud", "115200")
        flash_out = run_idf_command(project_path, ["-p", port, "-b", baud, "flash"])
        return [TextContent(type="text", text=flash_out)]

    elif name == "get_size":
        size_out = run_idf_command(project_path, ["size"])
        return [TextContent(type="text", text=size_out)]

    elif name == "clean":
        clean_out = run_idf_command(project_path, ["fullclean"])
        return [TextContent(type="text", text=clean_out)]

    return [TextContent(type="text", text=f"알 수 없는 도구: {name}")]

async def main():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())

if __name__ == "__main__":
    asyncio.run(main())
